#!/usr/bin/env elixir

# Local test script using gcloud auth for AlloyDB connector

defmodule LocalTest do
  def run do
    IO.puts("\n🚀 AlloyDB Connector Local Test")
    IO.puts("=" |> String.duplicate(60))
    
    # Get access token from gcloud
    IO.puts("\n1️⃣  Getting access token from gcloud...")
    
    token = case System.cmd("gcloud", ["auth", "print-access-token"]) do
      {token, 0} -> 
        token = String.trim(token)
        IO.puts("   ✅ Token obtained (#{String.length(token)} chars)")
        token
      _ ->
        IO.puts("   ❌ Failed to get token from gcloud")
        IO.puts("   Run: gcloud auth login")
        System.halt(1)
    end
    
    # Test the connector with the token directly
    IO.puts("\n2️⃣  Testing metadata exchange protocol...")
    
    # Create a mock token provider
    token_provider = fn -> token end
    
    # Test direct connection
    socket_result = test_direct_connection(token)
    
    case socket_result do
      {:ok, _} ->
        IO.puts("\n3️⃣  Testing Postgrex integration...")
        test_postgrex_with_token(token)
      _ ->
        IO.puts("\n   ⚠️  Skipping Postgrex test due to connection failure")
    end
    
    IO.puts("\n" <> String.duplicate("=", 60))
  end
  
  defp test_direct_connection(token) do
    # Build request manually for testing
    alias AlloydbConnector.Proto.MetadataExchangeRequest
    alias AlloydbConnector.Proto.MetadataExchangeResponse
    
    request = %MetadataExchangeRequest{
      user_agent: "alloydb-elixir-test/0.1.0",
      auth_type: :AUTO_IAM,
      oauth2_token: token
    }
    
    # Test encoding
    encoded = MetadataExchangeRequest.encode(request)
    IO.puts("   📦 Request encoded: #{byte_size(encoded)} bytes")
    
    # Try to connect
    case :gen_tcp.connect('10.56.0.2', 5433, [:binary, active: false, packet: :raw], 5000) do
      {:ok, socket} ->
        IO.puts("   ✅ TCP connection established to 10.56.0.2:5433")
        
        # Try SSL handshake
        ssl_opts = [
          verify: :verify_none,
          versions: [:"tlsv1.2", :"tlsv1.3"]
        ]
        
        case :ssl.connect(socket, ssl_opts, 5000) do
          {:ok, ssl_socket} ->
            IO.puts("   ✅ SSL handshake completed")
            
            # Send metadata exchange
            packet = <<byte_size(encoded)::32-big>> <> encoded
            
            case :ssl.send(ssl_socket, packet) do
              :ok ->
                IO.puts("   📤 Metadata exchange request sent")
                
                # Try to read response
                case :ssl.recv(ssl_socket, 4, 5000) do
                  {:ok, <<resp_len::32-big>>} ->
                    IO.puts("   📥 Response length: #{resp_len} bytes")
                    
                    case :ssl.recv(ssl_socket, resp_len, 5000) do
                      {:ok, resp_data} ->
                        response = MetadataExchangeResponse.decode(resp_data)
                        IO.puts("   📦 Response decoded: #{inspect(response.response_code)}")
                        
                        if response.response_code == :OK do
                          IO.puts("   ✅ Metadata exchange successful!")
                          :ssl.close(ssl_socket)
                          {:ok, :success}
                        else
                          IO.puts("   ❌ Exchange failed: #{response.error}")
                          :ssl.close(ssl_socket)
                          {:error, response.error}
                        end
                        
                      {:error, reason} ->
                        IO.puts("   ❌ Failed to read response: #{inspect(reason)}")
                        :ssl.close(ssl_socket)
                        {:error, reason}
                    end
                    
                  {:error, reason} ->
                    IO.puts("   ❌ Failed to read response length: #{inspect(reason)}")
                    :ssl.close(ssl_socket)
                    {:error, reason}
                end
                
              {:error, reason} ->
                IO.puts("   ❌ Failed to send request: #{inspect(reason)}")
                :ssl.close(ssl_socket)
                {:error, reason}
            end
            
          {:error, reason} ->
            IO.puts("   ❌ SSL handshake failed: #{inspect(reason)}")
            :gen_tcp.close(socket)
            {:error, reason}
        end
        
      {:error, reason} ->
        IO.puts("   ❌ TCP connection failed: #{inspect(reason)}")
        IO.puts("\n   Troubleshooting:")
        IO.puts("   • Are you running this from within the VPC?")
        IO.puts("   • Is AlloyDB accessible on 10.56.0.2:5433?")
        IO.puts("   • Try: telnet 10.56.0.2 5433")
        {:error, reason}
    end
  end
  
  defp test_postgrex_with_token(token) do
    # Start a simple GenServer to provide the token
    {:ok, token_provider} = Agent.start_link(fn -> token end)
    
    # Create a module function that Postgrex can call
    token_fn = fn -> Agent.get(token_provider, & &1) end
    
    user_email = case System.cmd("gcloud", ["config", "get-value", "account"]) do
      {email, 0} -> String.trim(email)
      _ -> "gcp-failsafe@u2i.com"
    end
    
    IO.puts("   Testing with user: #{user_email}")
    
    config = [
      hostname: "10.56.0.2",
      port: 5433,
      database: "postgres",
      username: user_email,
      password_provider: token_fn,
      ssl: true,
      ssl_opts: [verify: :verify_none],
      timeout: 15_000,
      show_sensitive_data_on_connection_error: true
    ]
    
    case Postgrex.start_link(config) do
      {:ok, conn} ->
        IO.puts("   ✅ Connected via Postgrex!")
        
        {:ok, result} = Postgrex.query(conn, "SELECT current_user", [])
        [[user]] = result.rows
        IO.puts("   📊 Current user: #{user}")
        
        GenServer.stop(conn)
        Agent.stop(token_provider)
        
      {:error, error} ->
        IO.puts("   ❌ Postgrex connection failed: #{inspect(error)}")
        Agent.stop(token_provider)
    end
  end
end

# Run the test
LocalTest.run()