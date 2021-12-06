import Config

require Logger

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.

{worker, webserver} =
  case config_env() do
    :prod ->
      {
        System.get_env("WORKER") || raise("expected the WORKER environment variable to be set"),
        System.get_env("WEBSERVER") || raise("expected the WEBSERVER variable to be set")
      }

    :dev ->
      # By default in dev, the application will be both a worker and a webserver
      {
        System.get_env("WORKER", "1"),
        System.get_env("WEBSERVER", "1")
      }

    :test ->
      {
        "0",
        "0"
      }
  end

worker = worker == "1"
webserver = webserver == "1"

# expose the result so that the application can configure itself from there
config :transport,
  worker: worker,
  webserver: webserver

# Inside IEx, we do not want jobs to start processing, nor plugins working.
# The jobs can be heavy and for instance in production, one person could
# unknowningly create duplicate RAM heavy jobs. With this trick, we can still
# enqueue jobs from IEx, but only the real worker will process them
# See https://github.com/sorentwo/oban/issues/520#issuecomment-883416363
iex_started? = Code.ensure_loaded?(IEx) && IEx.started?()

# Scheduled jobs (via Quantum at this point) are run in production and only on the first worker node
# https://www.clever-cloud.com/doc/reference/reference-environment-variables/#set-by-the-deployment-process
# They should not run in an iex session either.
if config_env() == :prod && !iex_started? && worker && System.fetch_env!("INSTANCE_NUMBER") == "0" do
  config :transport, Transport.Scheduler, jobs: Transport.Scheduler.scheduled_jobs()
end

# Make sure that APP_ENV is set in production to distinguish
# production and staging (both running with MIX_ENV=prod)
# See https://github.com/etalab/transport-site/issues/1945
app_env = System.get_env("APP_ENV", "") |> String.to_atom()
app_env_is_valid = Enum.member?([:production, :staging], app_env)

if config_env() == :prod and not app_env_is_valid do
  raise("APP_ENV must be set to production or staging while in production")
end

config :transport,
  app_env: app_env

# Override configuration specific to staging
if app_env == :staging do
  config :transport,
    s3_buckets: %{
      history: "resource-history-staging"
    }
end

base_oban_conf = [repo: DB.Repo]

# Oban jobs that should be run in every environment
oban_crontab_all_envs = [
  {"* */6 * * *", Transport.Jobs.ResourceHistoryDispatcherJob}
]

# Oban jobs that *should not* be run in staging by the crontab
non_staging_crontab =
  if app_env == :staging do
    []
    # Oban jobs that should be run in all envs, *except* staging
  else
    []
  end

extra_oban_conf =
  if not worker || (iex_started? and config_env() == :prod) || config_env() == :test do
    [queues: false, plugins: false]
  else
    [
      queues: [default: 2, heavy: 1],
      plugins: [
        {Oban.Plugins.Pruner, max_age: 60 * 60 * 24},
        {Oban.Plugins.Cron, crontab: List.flatten(oban_crontab_all_envs, non_staging_crontab)}
      ]
    ]
  end

config :transport, Oban, Keyword.merge(base_oban_conf, extra_oban_conf)

# here we only override specific keys. As documented in https://hexdocs.pm/elixir/master/Config.html#config/2,
# for keywords there is a recursive deep-merge, which should work nicely here.
if config_env() == :dev do
  config :transport, TransportWeb.Endpoint,
    # optionally allowing to override the port is useful to play with 2 nodes locally, without conflict
    http: [port: System.get_env("PORT", "5000")],
    #  We also make sure to start the assets watcher only if the webserver is up, to avoid cluttering the logs.
    watchers: if(webserver, do: [npm: ["run", "--prefix", "apps/transport/client", "watch"]], else: [])
end
