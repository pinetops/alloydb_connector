#!/usr/bin/env elixir

# Integration test for AlloyDB Connector with Postgrex
# This demonstrates the complete flow using the socket provider pattern

defmodule IntegrationTest do
  def run do
    IO.puts("\n🚀 Testing AlloyDB Connector + Postgrex Integration")
    IO.puts("=" |> String.duplicate(60))
    
    # Start Goth for OAuth token management
    {:ok, _} = Goth.start_link(
      name: MyGoth,
      source: {:service_account, credentials_path: "/path/to/service-account.json"},
      scopes: ["https://www.googleapis.com/auth/cloud-platform"]
    )
    
    IO.puts("✅ Goth started for OAuth token management")
    
    # Configuration for Postgrex with AlloyDB socket provider
    config = [
      # Use our custom socket provider
      socket_provider: {AlloydbConnector.Connector, :socket_provider},
      
      # Connection details (these get passed to the socket provider)
      hostname: "alloydb-iam-test",  # For logging/identification
      database: "postgres",
      username: "test-user@example.com",  # IAM user
      
      # AlloyDB-specific options (socket provider will use these)
      instance_uri: "projects/u2i-bootstrap/locations/us-central1/clusters/alloydb-iam-test/instances/alloydb-primary",
      enable_iam_auth: true,
      goth_name: MyGoth,
      
      # Connection pool settings
      pool_size: 5,
      timeout: 30_000
    ]
    
    IO.puts("📋 Configuration:")
    IO.puts("  Instance: #{config[:instance_uri]}")
    IO.puts("  IAM Auth: #{config[:enable_iam_auth]}")
    IO.puts("  Username: #{config[:username]}")
    IO.puts("  Database: #{config[:database]}")
    
    # Connect to AlloyDB
    IO.puts("\n🔌 Connecting to AlloyDB...")
    
    case Postgrex.start_link(config) do
      {:ok, conn} ->
        IO.puts("✅ Connected successfully!")
        
        # Run test queries
        run_test_queries(conn)
        
        # Close connection
        GenServer.stop(conn)
        IO.puts("\n✅ Test completed successfully!")
        
      {:error, reason} ->
        IO.puts("❌ Connection failed: #{inspect(reason)}")
    end
  end
  
  defp run_test_queries(conn) do
    IO.puts("\n📊 Running test queries...")
    
    # Test 1: Simple query
    case Postgrex.query(conn, "SELECT current_user, current_database()", []) do
      {:ok, result} ->
        [[user, db]] = result.rows
        IO.puts("  Current user: #{user}")
        IO.puts("  Current database: #{db}")
      {:error, err} ->
        IO.puts("  ❌ Query failed: #{inspect(err)}")
    end
    
    # Test 2: Version info
    case Postgrex.query(conn, "SELECT version()", []) do
      {:ok, result} ->
        [[version]] = result.rows
        IO.puts("  PostgreSQL version: #{String.slice(version, 0..50)}...")
      {:error, err} ->
        IO.puts("  ❌ Version query failed: #{inspect(err)}")
    end
    
    # Test 3: Create and query a table
    IO.puts("\n  Testing DDL and DML operations...")
    
    # Create table
    case Postgrex.query(conn, """
      CREATE TEMP TABLE test_table (
        id SERIAL PRIMARY KEY,
        name TEXT,
        created_at TIMESTAMP DEFAULT NOW()
      )
    """, []) do
      {:ok, _} ->
        IO.puts("  ✅ Created temporary table")
        
        # Insert data
        case Postgrex.query(conn, """
          INSERT INTO test_table (name) VALUES ($1), ($2), ($3)
          RETURNING id, name
        """, ["Alice", "Bob", "Charlie"]) do
          {:ok, result} ->
            IO.puts("  ✅ Inserted #{result.num_rows} rows")
            
            # Query data
            case Postgrex.query(conn, "SELECT * FROM test_table ORDER BY id", []) do
              {:ok, result} ->
                IO.puts("  ✅ Retrieved #{result.num_rows} rows:")
                for row <- result.rows do
                  [id, name, _timestamp] = row
                  IO.puts("     #{id}: #{name}")
                end
              {:error, err} ->
                IO.puts("  ❌ Select failed: #{inspect(err)}")
            end
            
          {:error, err} ->
            IO.puts("  ❌ Insert failed: #{inspect(err)}")
        end
        
      {:error, err} ->
        IO.puts("  ❌ Create table failed: #{inspect(err)}")
    end
    
    # Test 4: Transaction
    IO.puts("\n  Testing transaction...")
    
    Postgrex.transaction(conn, fn conn ->
      {:ok, _} = Postgrex.query(conn, "CREATE TEMP TABLE tx_test (id INT)", [])
      {:ok, _} = Postgrex.query(conn, "INSERT INTO tx_test VALUES (1), (2)", [])
      {:ok, result} = Postgrex.query(conn, "SELECT COUNT(*) FROM tx_test", [])
      [[count]] = result.rows
      IO.puts("  ✅ Transaction completed, inserted #{count} rows")
    end)
  end
end

# Check if we're running in a Mix project
if Code.ensure_loaded?(Mix) do
  # We're in a Mix project, dependencies should already be loaded
  IntegrationTest.run()
else
  # Running as a script, install dependencies
  Mix.install([
    {:postgrex, path: "/Users/tom/dev/postgrex"},
    {:alloydb_connector, path: "/Users/tom/dev/alloydb_connector"},
    {:goth, github: "pinetops/goth", branch: "alloydb-support"}
  ])
  
  IntegrationTest.run()
end