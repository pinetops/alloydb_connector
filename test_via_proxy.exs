#!/usr/bin/env elixir

# Test via auth proxy to verify our implementation matches expected behavior

defmodule ProxyTest do
  def run do
    IO.puts("\n🚀 Testing via Auth Proxy (Port 15433)")
    IO.puts("=" |> String.duplicate(60))
    
    # Get token
    token = case System.cmd("gcloud", ["auth", "print-access-token"]) do
      {token, 0} -> String.trim(token)
      _ -> 
        IO.puts("Failed to get token")
        System.halt(1)
    end
    
    user_email = case System.cmd("gcloud", ["config", "get-value", "account"]) do
      {email, 0} -> String.trim(email)
      _ -> "gcp-failsafe@u2i.com"
    end
    
    IO.puts("User: #{user_email}")
    IO.puts("Token length: #{String.length(token)}")
    
    # Test connection through proxy using OAuth token as password
    config = [
      hostname: "127.0.0.1",
      port: 15433,
      database: "postgres",
      username: user_email,
      password: token,
      ssl: false,  # Proxy handles SSL
      timeout: 15_000
    ]
    
    case Postgrex.start_link(config) do
      {:ok, conn} ->
        IO.puts("✅ Connected through auth proxy!")
        
        {:ok, result} = Postgrex.query(conn, "SELECT current_user, version()", [])
        [[user, version]] = result.rows
        IO.puts("Current user: #{user}")
        IO.puts("PostgreSQL: #{version |> String.split("\n") |> hd()}")
        
        # Test that IAM auth worked
        {:ok, result} = Postgrex.query(conn, """
          SELECT usename, usesuper 
          FROM pg_user 
          WHERE usename = current_user
        """, [])
        
        [[username, is_super]] = result.rows
        IO.puts("IAM User: #{username}, Superuser: #{is_super}")
        
        GenServer.stop(conn)
        
      {:error, %Postgrex.Error{postgres: %{code: code, message: message}}} ->
        IO.puts("❌ Postgres error #{code}: #{message}")
        
      {:error, error} ->
        IO.puts("❌ Connection failed: #{inspect(error)}")
    end
    
    IO.puts("\n" <> String.duplicate("=", 60))
  end
end

ProxyTest.run()