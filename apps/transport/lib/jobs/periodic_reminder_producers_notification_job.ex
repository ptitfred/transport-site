defmodule Transport.Jobs.PeriodicReminderProducersNotificationJob do
  @moduledoc """
  This job sends emails to producers on the first Monday of a few months per year.
  The goals are to:
  - let them know that they could receive notifications
  - review notification settings
  - advertise about these features
  - review settings regarding colleagues/organisations
  - provide an opportunity to get in touch with our team

  Emails may be sent over multiple days if we have a large number to send, to
  avoid going over daily quotas and to spread the support load.
  """
  @min_days_before_sending_again 90
  @max_emails_per_day 100
  @notification_reason DB.NotificationSubscription.reason(:periodic_reminder_producers)

  use Oban.Worker,
    unique: [period: {@min_days_before_sending_again, :days}],
    max_attempts: 3,
    tags: ["notifications"]

  import Ecto.Query

  @impl Oban.Worker
  def perform(%Oban.Job{args: args, inserted_at: %DateTime{} = inserted_at}) when args == %{} or is_nil(args) do
    date = DateTime.to_date(inserted_at)

    if date == first_monday_of_month(date) do
      relevant_contacts() |> schedule_jobs(inserted_at)
    else
      {:discard, "Not the first Monday of the month"}
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"contact_id" => contact_id}}) do
    contact =
      DB.Contact.base_query()
      |> preload([:organizations, notification_subscriptions: [:dataset]])
      |> DB.Repo.get!(contact_id)

    if sent_mail_recently?(contact) do
      {:discard, "Mail has already been sent recently"}
    else
      if contact |> subscribed_as_producer?() do
        send_mail_producer_with_subscriptions(contact)
      else
        send_mail_producer_without_subscriptions(contact)
      end

      :ok
    end
  end

  defp relevant_contacts do
    orgs_with_dataset =
      DB.Dataset.base_query()
      |> select([dataset: d], d.organization_id)
      |> distinct(true)
      |> DB.Repo.all()
      |> MapSet.new()

    # Identify contacts we want to reach:
    # - they have at least a subscription as a producer (=> review settings)
    # - they don't have subscriptions but they are a member of an org
    #   with published datasets (=> advertise subscriptions)
    DB.Contact.base_query()
    |> preload([:organizations, :notification_subscriptions])
    |> join(:left, [contact: c], c in assoc(c, :organizations), as: :organization)
    |> order_by([organization: o], asc: o.id)
    |> DB.Repo.all()
    |> Enum.filter(fn %DB.Contact{organizations: orgs} = contact ->
      org_has_published_dataset? = not MapSet.disjoint?(MapSet.new(orgs, & &1.id), orgs_with_dataset)

      subscribed_as_producer?(contact) or org_has_published_dataset?
    end)
    |> Enum.uniq_by(& &1.id)
  end

  defp schedule_jobs(contacts, %DateTime{} = scheduled_at) do
    contacts
    |> Enum.map(fn %DB.Contact{id: id} -> id end)
    |> Enum.chunk_every(chunk_size())
    # credo:disable-for-next-line Credo.Check.Warning.UnusedEnumOperation
    |> Enum.reduce(scheduled_at, fn ids, %DateTime{} = scheduled_at ->
      ids
      |> Enum.map(&(%{"contact_id" => &1} |> new(scheduled_at: scheduled_at)))
      |> Oban.insert_all()

      next_weekday(scheduled_at)
    end)

    :ok
  end

  def sent_mail_recently?(%DB.Contact{email: email}) do
    dt_limit = DateTime.utc_now() |> DateTime.add(-@min_days_before_sending_again, :day)

    DB.Notification
    |> where([n], n.email_hash == ^email and n.reason == ^@notification_reason and n.inserted_at >= ^dt_limit)
    |> DB.Repo.exists?()
  end

  defp send_mail_producer_without_subscriptions(%DB.Contact{organizations: orgs} = contact) do
    datasets =
      orgs
      |> DB.Repo.preload(:datasets)
      |> Enum.flat_map(& &1.datasets)
      |> Enum.uniq()
      |> Enum.filter(&DB.Dataset.active?/1)
      |> Enum.sort_by(fn %DB.Dataset{custom_title: custom_title} -> custom_title end)

    Transport.EmailSender.impl().send_mail(
      "transport.data.gouv.fr",
      Application.get_env(:transport, :contact_email),
      contact.email,
      Application.get_env(:transport, :contact_email),
      "Notifications pour vos données sur transport.data.gouv.fr",
      "",
      Phoenix.View.render_to_string(TransportWeb.EmailView, "producer_without_subscriptions.html", %{datasets: datasets})
    )

    DB.Notification.insert!(@notification_reason, contact.email)
  end

  defp send_mail_producer_with_subscriptions(%DB.Contact{} = contact) do
    other_producers_subscribers = contact |> other_producers_subscribers()

    Transport.EmailSender.impl().send_mail(
      "transport.data.gouv.fr",
      Application.get_env(:transport, :contact_email),
      contact.email,
      Application.get_env(:transport, :contact_email),
      "Rappel : vos notifications pour vos données sur transport.data.gouv.fr",
      "",
      Phoenix.View.render_to_string(TransportWeb.EmailView, "producer_with_subscriptions.html", %{
        datasets_subscribed: contact |> datasets_subscribed_as_producer(),
        has_other_producers_subscribers: not Enum.empty?(other_producers_subscribers),
        other_producers_subscribers: Enum.map_join(other_producers_subscribers, ", ", &DB.Contact.display_name/1)
      })
    )

    DB.Notification.insert!(@notification_reason, contact.email)
  end

  @spec datasets_subscribed_as_producer(DB.Contact.t()) :: [DB.Dataset.t()]
  def datasets_subscribed_as_producer(%DB.Contact{notification_subscriptions: subscriptions}) do
    subscriptions
    |> Enum.filter(&(&1.role == :producer))
    |> Enum.map(& &1.dataset)
    |> Enum.uniq()
    |> Enum.sort_by(& &1.custom_title)
  end

  @spec subscribed_as_producer?(DB.Contact.t()) :: boolean()
  def subscribed_as_producer?(%DB.Contact{notification_subscriptions: subscriptions}) do
    Enum.any?(subscriptions, &match?(%DB.NotificationSubscription{role: :producer}, &1))
  end

  @spec other_producers_subscribers(DB.Contact.t()) :: [DB.Contact.t()]
  def other_producers_subscribers(%DB.Contact{id: contact_id, notification_subscriptions: subscriptions}) do
    dataset_ids = subscriptions |> Enum.map(& &1.dataset_id) |> Enum.uniq()

    DB.NotificationSubscription.base_query()
    |> preload(:contact)
    |> where(
      [notification_subscription: ns],
      ns.contact_id != ^contact_id and ns.role == :producer and ns.dataset_id in ^dataset_ids
    )
    |> DB.Repo.all()
    |> Enum.map(& &1.contact)
    |> Enum.uniq()
    # transport.data.gouv.fr's members who are subscribed as "producers" shouldn't be included.
    # they are dogfooding the feature
    |> Enum.reject(fn %DB.Contact{id: contact_id} -> contact_id in admin_contact_ids() end)
    |> Enum.sort_by(&DB.Contact.display_name/1)
  end

  @doc """
  A list of contact_ids for contacts who are members of the transport.data.gouv.fr's organization.

  This list is cached because it is very stable over time and we need it for multiple
  Oban jobs executed in parallel or one after another.
  """
  @spec admin_contact_ids() :: [integer()]
  def admin_contact_ids do
    Transport.Cache.API.fetch(
      to_string(__MODULE__) <> ":admin_contact_ids",
      fn -> Enum.map(admin_contacts(), & &1.id) end,
      :timer.seconds(60)
    )
  end

  @doc """
  Fetches `DB.Contact` who are members of the transport.data.gouv.fr's organization.
  """
  @spec admin_contacts() :: [DB.Contact.t()]
  def admin_contacts do
    pan_org_name = Application.fetch_env!(:transport, :datagouvfr_transport_publisher_label)

    DB.Organization.base_query()
    |> preload(:contacts)
    |> where([organization: o], o.name == ^pan_org_name)
    |> DB.Repo.one!()
    |> Map.fetch!(:contacts)
  end

  @doc """
  How many e-mails are we going to send per day?
  Our daily free limit quota is set at 200 per day so we don't want to go over that.
  We set the chunk size to 1 in the test env to test the scheduling logic.
  """
  def chunk_size do
    case Mix.env() do
      :test -> 1
      _ -> @max_emails_per_day
    end
  end

  @doc """
  iex> first_monday_of_month(~D[2023-07-10])
  ~D[2023-07-03]
  iex> first_monday_of_month(~D[2023-08-07])
  ~D[2023-08-07]
  iex> first_monday_of_month(~D[2023-10-16])
  ~D[2023-10-02]
  iex> first_monday_of_month(~D[2024-01-08])
  ~D[2024-01-01]
  iex> first_monday_of_month(~D[2024-01-01])
  ~D[2024-01-01]
  """
  def first_monday_of_month(%Date{} = date) do
    1..8
    |> Enum.map(fn day -> %Date{date | day: day} end)
    |> Enum.find(&(Date.day_of_week(&1) == 1))
  end

  @doc """
  Returns the following weekday, avoiding Saturdays and Sundays.

  iex> next_weekday(~U[2023-07-28 09:05:00Z])
  ~U[2023-07-31 09:05:00Z]
  iex> next_weekday(~U[2023-07-29 09:05:00Z])
  ~U[2023-07-31 09:05:00Z]
  iex> next_weekday(~U[2023-07-30 09:05:00Z])
  ~U[2023-07-31 09:05:00Z]
  iex> next_weekday(~U[2023-07-31 09:05:00Z])
  ~U[2023-08-01 09:05:00Z]
  iex> next_weekday(~U[2023-08-01 09:05:00Z])
  ~U[2023-08-02 09:05:00Z]
  """
  def next_weekday(%DateTime{} = datetime) do
    datetime = datetime |> DateTime.add(1, :day)

    if (datetime |> DateTime.to_date() |> Date.day_of_week()) in [6, 7] do
      next_weekday(datetime)
    else
      datetime
    end
  end
end
