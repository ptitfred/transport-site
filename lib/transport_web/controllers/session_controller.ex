defmodule TransportWeb.SessionController do
  @moduledoc """
  Session management for transport.
  """

  use TransportWeb, :controller
  alias Transport.Datagouvfr.{Authentication, Client.User}
  require Logger

  def new(conn, _) do
    redirect(conn, external: Authentication.authorize_url!)
  end

  def create(conn, %{"code" => code}) do
    client = Authentication.get_token!(code: code)
    conn
    |> assign(:client, client)
    |> User.me()
    |> case do
      {:ok, user} ->
        conn
        |> put_session(:current_user, user_params(user))
        |> put_session(:client, client)
        |> redirect(to: get_redirect_path(conn))
        |> halt()
      {:error, error} ->
        Logger.error(error)
        conn
        |> put_flash(:error, dgettext("alert", "An error occured, please try again"))
        |> redirect(to: session_path(conn, :new))
        |> halt()
    end
  end

  def delete(conn, _) do
    conn
    |> configure_session(drop: true)
    |> redirect(to: page_path(conn, :index))
    |> halt()
  end

  #private functions

  defp user_params(%{} = user) do
    Map.take(user, ["id", "apikey", "email", "first_name", "last_name"])
  end

  defp get_redirect_path(conn) do
    case get_session(conn, :redirect_path) do
      nil -> "/"
      path -> path
    end
  end
end
