defmodule AlloydbConnector.AdminClient do
  @moduledoc """
  Client for AlloyDB Admin API operations.
  Handles getting connection info and generating ephemeral certificates.
  """
  
  require Logger
  
  @alloydb_api_endpoint "https://alloydb.googleapis.com"
  @api_version "v1beta"
  
  @doc """
  Get connection information for an AlloyDB instance.
  """
  def get_connection_info(instance_uri, oauth_token) do
    url = "#{@alloydb_api_endpoint}/#{@api_version}/#{instance_uri}/connectionInfo"
    
    headers = [
      {"Authorization", "Bearer #{oauth_token}"},
      {"Content-Type", "application/json"}
    ]
    
    case HTTPoison.get(url, headers) do
      {:ok, %{status_code: 200, body: body}} ->
        {:ok, Jason.decode!(body)}
      
      {:ok, %{status_code: code, body: body}} ->
        {:error, "Failed to get connection info: #{code} - #{body}"}
      
      {:error, reason} ->
        {:error, "HTTP request failed: #{inspect(reason)}"}
    end
  end
  
  @doc """
  Generate an ephemeral client certificate for mTLS authentication.
  
  Args:
    cluster_uri: projects/{project}/locations/{region}/clusters/{cluster}
    public_key_pem: PEM-encoded RSA public key
    oauth_token: OAuth2 access token
  
  Returns:
    {:ok, %{cert_chain: [...], ca_cert: "..."}} or {:error, reason}
  """
  def generate_client_certificate(cluster_uri, public_key_pem, oauth_token) do
    url = "#{@alloydb_api_endpoint}/#{@api_version}/#{cluster_uri}:generateClientCertificate"
    
    # Build request body
    body = %{
      "pemCsr": public_key_pem,
      # Certificate valid for 24 hours
      "certDuration": "86400s"
    }
    
    headers = [
      {"Authorization", "Bearer #{oauth_token}"},
      {"Content-Type", "application/json"}
    ]
    
    case HTTPoison.post(url, Jason.encode!(body), headers) do
      {:ok, %{status_code: 200, body: response_body}} ->
        response = Jason.decode!(response_body)
        
        # Extract certificates from response
        {:ok, %{
          cert_chain: response["pemCertificateChain"],
          ca_cert: response["caCert"]
        }}
      
      {:ok, %{status_code: code, body: body}} ->
        Logger.error("Failed to generate certificate: #{code} - #{body}")
        {:error, "Certificate generation failed: #{code}"}
      
      {:error, reason} ->
        Logger.error("HTTP request failed: #{inspect(reason)}")
        {:error, "HTTP request failed: #{inspect(reason)}"}
    end
  end
  
  @doc """
  Build the full instance URI from components.
  """
  def build_instance_uri(project, region, cluster, instance) do
    "projects/#{project}/locations/#{region}/clusters/#{cluster}/instances/#{instance}"
  end
  
  @doc """
  Build the cluster URI from instance URI.
  """
  def build_cluster_uri(instance_uri) do
    # Remove /instances/{instance} from the end
    instance_uri
    |> String.split("/instances/")
    |> List.first()
  end
end