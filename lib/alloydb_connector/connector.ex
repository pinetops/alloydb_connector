defmodule AlloydbConnector.Connector do
  @moduledoc """
  AlloyDB Connector that implements the full authentication flow including:
  1. Generating ephemeral certificates via AlloyDB Admin API
  2. Establishing mTLS connection using those certificates
  3. Performing metadata exchange protocol for IAM authentication
  
  This allows direct IAM authentication without the auth proxy.
  """
  
  require Logger
  
  alias AlloydbConnector.AdminClient
  alias AlloydbConnector.Crypto
  alias AlloydbConnector.Proto.MetadataExchangeRequest
  alias AlloydbConnector.Proto.MetadataExchangeResponse
  
  # AlloyDB server-side proxy port
  @server_proxy_port 5433
  @io_timeout 30_000
  
  @doc """
  Connect to AlloyDB instance with IAM authentication using ephemeral certificates.
  
  ## Options
  
    * `:instance_uri` - Full instance URI: projects/{project}/locations/{region}/clusters/{cluster}/instances/{instance}
    * `:enable_iam_auth` - Enable IAM authentication (default: true)
    * `:goth_name` - Name of the Goth process for token fetching (required for IAM)
    * `:user_agent` - User agent string (optional)
  
  ## Examples
  
      iex> {:ok, socket} = AlloydbConnector.Connector.connect(
      ...>   instance_uri: "projects/my-project/locations/us-central1/clusters/my-cluster/instances/my-instance",
      ...>   enable_iam_auth: true,
      ...>   goth_name: MyGoth
      ...> )
  
  """
  def connect(opts) do
    instance_uri = Keyword.fetch!(opts, :instance_uri)
    enable_iam_auth = Keyword.get(opts, :enable_iam_auth, true)
    goth_name = Keyword.get(opts, :goth_name)
    user_agent = Keyword.get(opts, :user_agent, "alloydb-elixir-connector/0.1.0")
    
    # Get OAuth token if IAM auth is enabled
    oauth_token = if enable_iam_auth do
      fetch_oauth_token(goth_name)
    else
      nil
    end
    
    with {:ok, connection_info} <- get_connection_info(instance_uri, oauth_token),
         {:ok, certs} <- generate_ephemeral_certificates(instance_uri, oauth_token),
         {:ok, socket} <- establish_connection(connection_info.ip_address),
         {:ok, ssl_socket} <- wrap_with_mtls(socket, certs, connection_info.ip_address),
         :ok <- perform_metadata_exchange(ssl_socket, enable_iam_auth, oauth_token, user_agent) do
      {:ok, ssl_socket}
    else
      {:error, reason} = error ->
        Logger.error("AlloyDB connection failed: #{inspect(reason)}")
        error
    end
  end
  
  @doc """
  Socket provider function for Postgrex integration.
  
  This function is designed to be used with the :socket_provider option in Postgrex.
  
  ## Example
  
      config = [
        socket_provider: {AlloydbConnector.Connector, :socket_provider},
        socket_provider_options: [
          instance_uri: "projects/my-project/locations/us-central1/clusters/my-cluster/instances/my-instance",
          enable_iam_auth: true,
          goth_name: MyGoth
        ],
        database: "postgres",
        username: "user@example.com"
      ]
      
      {:ok, conn} = Postgrex.start_link(config)
  """
  def socket_provider(opts) do
    connect(opts)
  end
  
  # Private functions
  
  defp get_connection_info(instance_uri, oauth_token) do
    Logger.debug("Getting connection info for #{instance_uri}")
    
    case AdminClient.get_connection_info(instance_uri, oauth_token) do
      {:ok, info} ->
        ip_address = info["ipAddress"] || info["pscDnsName"]
        
        if ip_address do
          Logger.debug("Instance IP address: #{ip_address}")
          {:ok, %{ip_address: ip_address}}
        else
          {:error, "No IP address found in connection info"}
        end
      
      {:error, reason} ->
        {:error, {:connection_info_failed, reason}}
    end
  end
  
  defp generate_ephemeral_certificates(instance_uri, oauth_token) do
    Logger.debug("Generating ephemeral certificates")
    
    # Generate RSA key pair
    {private_key, public_key_pem} = Crypto.generate_rsa_keypair()
    
    # Get cluster URI from instance URI
    cluster_uri = AdminClient.build_cluster_uri(instance_uri)
    
    # Request ephemeral certificate from AlloyDB Admin API
    case AdminClient.generate_client_certificate(cluster_uri, public_key_pem, oauth_token) do
      {:ok, %{cert_chain: cert_chain, ca_cert: ca_cert}} ->
        Logger.debug("Ephemeral certificate generated (valid for 24 hours)")
        
        # First certificate in chain is the client cert
        client_cert = List.first(cert_chain)
        
        {:ok, %{
          private_key: private_key,
          client_cert: client_cert,
          ca_cert: ca_cert
        }}
      
      {:error, reason} ->
        {:error, {:certificate_generation_failed, reason}}
    end
  end
  
  defp establish_connection(ip_address) do
    Logger.debug("Connecting to AlloyDB at #{ip_address}:#{@server_proxy_port}")
    
    case :gen_tcp.connect(
      String.to_charlist(ip_address),
      @server_proxy_port,
      [:binary, active: false, packet: :raw],
      @io_timeout
    ) do
      {:ok, socket} ->
        Logger.debug("TCP connection established")
        {:ok, socket}
      {:error, reason} = error ->
        Logger.error("Failed to establish TCP connection: #{inspect(reason)}")
        error
    end
  end
  
  defp wrap_with_mtls(socket, certs, hostname) do
    Logger.debug("Establishing mTLS connection with ephemeral certificate")
    
    # Build SSL options with client certificate for mTLS
    ssl_opts = Crypto.ssl_options(
      certs.client_cert,
      certs.private_key,
      certs.ca_cert
    )
    
    # Add hostname for SNI
    ssl_opts = [{:server_name_indication, String.to_charlist(hostname)} | ssl_opts]
    
    case :ssl.connect(socket, ssl_opts, @io_timeout) do
      {:ok, ssl_socket} ->
        Logger.debug("mTLS handshake completed")
        {:ok, ssl_socket}
      {:error, reason} = error ->
        Logger.error("mTLS handshake failed: #{inspect(reason)}")
        :gen_tcp.close(socket)
        error
    end
  end
  
  defp perform_metadata_exchange(ssl_socket, enable_iam_auth, oauth_token, user_agent) do
    Logger.debug("Starting metadata exchange (IAM: #{enable_iam_auth})")
    
    # Determine auth type
    auth_type = if enable_iam_auth do
      :AUTO_IAM
    else
      :DB_NATIVE
    end
    
    # Build metadata exchange request
    request = %MetadataExchangeRequest{
      user_agent: user_agent,
      auth_type: auth_type,
      oauth2_token: oauth_token || ""
    }
    
    # Serialize the request
    request_bytes = MetadataExchangeRequest.encode(request)
    request_length = byte_size(request_bytes)
    
    # Send length (4 bytes big-endian) + serialized request
    packet = <<request_length::32-big>> <> request_bytes
    
    Logger.debug("Sending metadata exchange request (#{request_length} bytes)")
    
    case :ssl.send(ssl_socket, packet) do
      :ok ->
        receive_metadata_response(ssl_socket)
      {:error, reason} = error ->
        Logger.error("Failed to send metadata exchange request: #{inspect(reason)}")
        :ssl.close(ssl_socket)
        error
    end
  end
  
  defp receive_metadata_response(ssl_socket) do
    # Set timeout for receiving
    :ssl.setopts(ssl_socket, [{:active, false}])
    
    # Read response length (4 bytes)
    case :ssl.recv(ssl_socket, 4, @io_timeout) do
      {:ok, <<response_length::32-big>>} ->
        Logger.debug("Expecting metadata response of #{response_length} bytes")
        
        # Read response message
        case :ssl.recv(ssl_socket, response_length, @io_timeout) do
          {:ok, response_data} ->
            # Parse response
            response = MetadataExchangeResponse.decode(response_data)
            
            case response.response_code do
              :OK ->
                Logger.info("Metadata exchange successful - connection authenticated")
                # Reset socket to blocking mode for PostgreSQL protocol
                :ssl.setopts(ssl_socket, [{:active, false}])
                :ok
                
              :ERROR ->
                error_msg = response.error || "Unknown error"
                Logger.error("Metadata exchange failed: #{error_msg}")
                :ssl.close(ssl_socket)
                {:error, {:metadata_exchange_failed, error_msg}}
                
              code ->
                Logger.error("Unexpected response code: #{inspect(code)}")
                :ssl.close(ssl_socket)
                {:error, {:unexpected_response_code, code}}
            end
            
          {:error, reason} = error ->
            Logger.error("Failed to receive metadata response: #{inspect(reason)}")
            :ssl.close(ssl_socket)
            error
        end
        
      {:error, reason} = error ->
        Logger.error("Failed to receive metadata response length: #{inspect(reason)}")
        :ssl.close(ssl_socket)
        error
    end
  end
  
  defp fetch_oauth_token(nil) do
    raise ArgumentError, "goth_name is required for IAM authentication"
  end
  
  defp fetch_oauth_token(goth_name) do
    case Goth.fetch(goth_name) do
      {:ok, %{token: token}} ->
        Logger.debug("OAuth token fetched (#{String.length(token)} chars)")
        token
      {:error, reason} ->
        raise "Failed to fetch OAuth token from Goth: #{inspect(reason)}"
    end
  end
end