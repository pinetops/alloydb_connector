#!/usr/bin/env elixir

# Test script for AlloyDB connector with metadata exchange protocol

defmodule TestAlloyDB do
  def run do
    IO.puts("\n🚀 AlloyDB Connector Test with Metadata Exchange Protocol")
    IO.puts("=" |> String.duplicate(60))
    
    # Start Goth for token management
    IO.puts("\n1️⃣  Starting Goth for OAuth token management...")
    case Goth.start_link(name: AlloyDBGoth, source: {:metadata, []}) do
      {:ok, _} -> 
        IO.puts("   ✅ Goth started")
      {:error, {:already_started, _}} ->
        IO.puts("   ℹ️  Goth already running")
      {:error, reason} ->
        IO.puts("   ❌ Failed to start Goth: #{inspect(reason)}")
        System.halt(1)
    end
    
    # Test direct connector
    IO.puts("\n2️⃣  Testing AlloyDB connector metadata exchange...")
    
    test_connector_direct()
    
    IO.puts("\n3️⃣  Testing Postgrex integration with custom socket...")
    
    test_postgrex_integration()
    
    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("✅ All tests completed!")
  end
  
  defp test_connector_direct do
    # Test the metadata exchange directly
    opts = [
      instance_ip: "10.56.0.2",
      enable_iam_auth: true,
      goth_name: AlloyDBGoth,
      ssl_options: [verify: :verify_none]  # For testing within VPC
    ]
    
    case AlloydbConnector.Connector.connect(opts) do
      {:ok, socket} ->
        IO.puts("   ✅ Metadata exchange successful!")
        IO.puts("   📦 Socket ready for PostgreSQL protocol")
        :ssl.close(socket)
        
      {:error, reason} ->
        IO.puts("   ❌ Metadata exchange failed: #{inspect(reason)}")
        IO.puts("\n   Troubleshooting:")
        IO.puts("   • Check if AlloyDB instance is accessible on 10.56.0.2:5433")
        IO.puts("   • Verify IAM authentication is enabled on the cluster")
        IO.puts("   • Ensure service account has alloydb.client role")
    end
  end
  
  defp test_postgrex_integration do
    # Get current user email
    user_email = case System.cmd("gcloud", ["config", "get-value", "account"]) do
      {email, 0} -> String.trim(email)
      _ -> "gcp-failsafe@u2i.com"
    end
    
    IO.puts("   Testing with user: #{user_email}")
    
    # Configure Postgrex to use our custom socket
    config = [
      socket: {AlloydbConnector.Connector, :connect_socket},
      socket_options: [
        instance_ip: "10.56.0.2",
        enable_iam_auth: true,
        goth_name: AlloyDBGoth,
        ssl_options: [verify: :verify_none]
      ],
      database: "postgres",
      username: user_email,
      timeout: 15_000,
      show_sensitive_data_on_connection_error: true
    ]
    
    case Postgrex.start_link(config) do
      {:ok, conn} ->
        IO.puts("   ✅ Connected to AlloyDB via Postgrex!")
        
        # Run test queries
        {:ok, result} = Postgrex.query(conn, "SELECT current_user", [])
        [[current_user]] = result.rows
        IO.puts("   📊 Current user: #{current_user}")
        
        {:ok, result} = Postgrex.query(conn, "SELECT version()", [])
        [[version]] = result.rows
        IO.puts("   📊 PostgreSQL: #{version |> String.split("\n") |> hd()}")
        
        # Test write operations
        Postgrex.query(conn, "DROP TABLE IF EXISTS connector_test", [])
        {:ok, _} = Postgrex.query(conn, """
          CREATE TABLE connector_test (
            id SERIAL PRIMARY KEY,
            message TEXT,
            created_at TIMESTAMP DEFAULT NOW()
          )
        """, [])
        
        {:ok, _} = Postgrex.query(conn, """
          INSERT INTO connector_test (message) VALUES ($1)
        """, ["Hello from AlloyDB connector!"])
        
        {:ok, result} = Postgrex.query(conn, "SELECT COUNT(*) FROM connector_test", [])
        [[count]] = result.rows
        IO.puts("   📊 Test table has #{count} row(s)")
        
        GenServer.stop(conn)
        
      {:error, %Postgrex.Error{message: message}} ->
        IO.puts("   ❌ Postgrex connection failed: #{message}")
        
      {:error, reason} ->
        IO.puts("   ❌ Connection failed: #{inspect(reason)}")
    end
  end
end

# Run the test
TestAlloyDB.run()