# Example Phoenix/Ecto configuration for AlloyDB with IAM authentication

# config/runtime.exs or config/prod.exs

import Config

# Configure your database with AlloyDB connector
config :my_app, MyApp.Repo,
  # Use custom socket provider for AlloyDB connection
  socket_provider: {AlloydbConnector.Connector, :socket_provider},
  
  # Standard Postgrex options
  database: "myapp_production",
  username: System.get_env("ALLOYDB_IAM_USER"),  # e.g., "service-account@project.iam"
  pool_size: 10,
  timeout: 30_000,
  
  # AlloyDB-specific configuration
  instance_uri: System.get_env("ALLOYDB_INSTANCE_URI"),
  enable_iam_auth: true,
  goth_name: MyApp.Goth,  # Your Goth process name
  
  # Optional: custom user agent
  user_agent: "myapp-phoenix/1.0"

# Configure Goth for OAuth token management
config :goth,
  json: System.get_env("GOOGLE_APPLICATION_CREDENTIALS_JSON") |> Jason.decode!(),
  # Or use ADC:
  # source: :default

# In your application.ex supervisor tree:
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    children = [
      # Start Goth before the Repo
      {Goth, name: MyApp.Goth, source: :default},
      
      # Start the Ecto repository
      MyApp.Repo,
      
      # Start the PubSub system
      {Phoenix.PubSub, name: MyApp.PubSub},
      
      # Start the Endpoint
      MyApp.Endpoint
    ]

    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end