defmodule AlloydbConnector.Crypto do
  @moduledoc """
  Cryptographic utilities for AlloyDB connector.
  Handles RSA key generation and certificate management.
  """

  @doc """
  Generate an RSA key pair for ephemeral certificate requests.
  Returns {private_key, public_key_pem}
  """
  def generate_rsa_keypair(bits \\ 2048) do
    # Generate RSA private key
    private_key = :public_key.generate_key({:rsa, bits, 65537})
    
    # Extract public key
    public_key = extract_public_key(private_key)
    
    # Convert public key to PEM format for API request
    public_key_der = :public_key.der_encode(:RSAPublicKey, public_key)
    public_key_pem = :public_key.pem_encode([{:RSAPublicKey, public_key_der, :not_encrypted}])
    
    {private_key, public_key_pem}
  end
  
  defp extract_public_key({:RSAPrivateKey, _, modulus, public_exponent, _, _, _, _, _, _, _}) do
    {:RSAPublicKey, modulus, public_exponent}
  end
  
  @doc """
  Create SSL options with client certificate for mTLS.
  """
  def ssl_options(client_cert_pem, private_key, ca_cert_pem, cert_chain \\ []) do
    # Parse client certificate
    [{:Certificate, client_cert_der, _}] = :public_key.pem_decode(client_cert_pem)
    
    # Parse CA certificate
    [{:Certificate, ca_cert_der, _}] = :public_key.pem_decode(ca_cert_pem)
    
    # Parse intermediate certificates from chain
    intermediate_certs = Enum.flat_map(cert_chain, fn cert_pem ->
      case :public_key.pem_decode(cert_pem) do
        [{:Certificate, cert_der, _}] -> [cert_der]
        _ -> []
      end
    end)
    
    # Build full CA chain (intermediates + root CA)
    ca_chain = intermediate_certs ++ [ca_cert_der]
    
    # Convert private key to DER format for SSL
    private_key_der = :public_key.der_encode(:RSAPrivateKey, private_key)
    
    [
      cert: client_cert_der,
      key: {:RSAPrivateKey, private_key_der},
      cacerts: ca_chain,
      verify: :verify_none,  # AlloyDB uses self-signed certificates
      versions: [:"tlsv1.3", :"tlsv1.2"],
      ciphers: :ssl.cipher_suites(:all, :"tlsv1.3") ++ :ssl.cipher_suites(:all, :"tlsv1.2")
    ]
  end
end