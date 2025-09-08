# Implementation Details

## IMPORTANT DISCOVERY

AlloyDB port 5433 requires mTLS with ephemeral certificates. The connectors work as follows:

1. **Generate RSA key pair** - Create a 2048-bit RSA key pair locally
2. **Call GenerateClientCertificate API** - Send public key to AlloyDB Admin API to get signed certificate (valid 24 hours)
3. **Establish mTLS connection** - Connect to port 5433 using the ephemeral certificate
4. **Perform metadata exchange** - Send Protocol Buffer MetadataExchangeRequest with OAuth token
5. **Continue with PostgreSQL protocol** - After successful exchange, socket is ready for Postgrex

This is NOT just a metadata exchange - it requires the AlloyDB Admin API for certificate generation!

## Protocol Buffer Messages

### MetadataExchangeRequest

```protobuf
message MetadataExchangeRequest {
  enum AuthType {
    AUTH_TYPE_UNSPECIFIED = 0;
    DB_NATIVE = 1;
    AUTO_IAM = 2;
  }
  
  string user_agent = 1;
  AuthType auth_type = 2;
  string oauth2_token = 3;
}
```

### MetadataExchangeResponse

```protobuf
message MetadataExchangeResponse {
  enum ResponseCode {
    RESPONSE_CODE_UNSPECIFIED = 0;
    OK = 1;
    ERROR = 2;
  }
  
  ResponseCode response_code = 1;
  string error = 2;
}
```

## Wire Protocol

The metadata exchange follows this sequence:

```
Client                           AlloyDB Port 5433
  |                                    |
  |------ TCP Connect --------------->|
  |                                    |
  |------ SSL Handshake ------------->|
  |<----- SSL Established ------------|
  |                                    |
  |------ Send 4-byte length -------->|
  |------ Send Request Protobuf ----->|
  |                                    |
  |<----- Send 4-byte length ---------|
  |<----- Send Response Protobuf -----|
  |                                    |
  |------ PostgreSQL Protocol ------->|
  |<----- PostgreSQL Protocol --------|
```

## Code Structure

### 1. Proto Module (`lib/alloydb_connector/proto.ex`)

Implements a minimal protobuf encoder/decoder specifically for the metadata exchange messages:

```elixir
# Encoding
request = %MetadataExchangeRequest{
  user_agent: "alloydb-elixir/0.1.0",
  auth_type: :AUTO_IAM,
  oauth2_token: token
}
encoded = MetadataExchangeRequest.encode(request)

# Decoding
response = MetadataExchangeResponse.decode(response_bytes)
```

### 2. Connector Module (`lib/alloydb_connector/connector.ex`)

Main connection logic:

```elixir
def connect(opts) do
  # 1. Get OAuth token
  oauth_token = fetch_oauth_token(goth_name)
  
  # 2. Establish TCP connection
  {:ok, socket} = establish_connection(instance_ip)
  
  # 3. Wrap with SSL
  {:ok, ssl_socket} = wrap_with_ssl(socket, ssl_options, instance_ip)
  
  # 4. Perform metadata exchange
  :ok = perform_metadata_exchange(ssl_socket, enable_iam_auth, oauth_token, user_agent)
  
  # 5. Return authenticated socket
  {:ok, ssl_socket}
end
```

### 3. Postgrex Integration

Uses the custom socket provider feature:

```elixir
def connect_socket(opts) do
  # Called by Postgrex to get a socket
  connect(opts)
end
```

## Testing Strategy

### Unit Tests

1. **Protobuf Encoding/Decoding**
   - Test message serialization
   - Test varint encoding
   - Test field ordering

2. **Connection Logic**
   - Mock socket connections
   - Test SSL wrapping
   - Test error handling

### Integration Tests

1. **With Auth Proxy** (for comparison)
   - Connect through proxy with OAuth token
   - Verify same behavior as direct connection

2. **Direct Connection** (requires VPC access)
   - Connect directly to port 5433
   - Perform metadata exchange
   - Execute queries

### Test Helpers

```elixir
# Get token from gcloud for testing
token = System.cmd("gcloud", ["auth", "print-access-token"])
        |> elem(0)
        |> String.trim()

# Mock Goth for testing
{:ok, _} = Agent.start_link(fn -> token end, name: TestGoth)
```

## Security Considerations

### Token Management

- Tokens are fetched fresh for each connection
- Goth handles automatic refresh (1-hour expiry)
- Tokens are never logged or persisted

### Network Security

- Connections must be within VPC or via Private Service Connect
- SSL/TLS is mandatory for metadata exchange
- Certificate verification should be enabled in production

### IAM Permissions

Required roles:
- `alloydb.client` - Basic connection permission
- `alloydb.databaseUser` - For database operations

## Performance Considerations

### Connection Overhead

- Metadata exchange adds ~50-100ms to connection time
- OAuth token fetch may add 10-50ms (cached by Goth)
- SSL handshake is required (same as auth proxy)

### Connection Pooling

- Each connection performs its own metadata exchange
- Postgrex connection pool minimizes connection creation
- Consider higher `pool_size` for high-throughput applications

### Comparison with Auth Proxy

| Metric | Auth Proxy | Direct Connector |
|--------|------------|------------------|
| Connection Latency | 2 hops | 1 hop |
| Memory Usage | Separate process | In-process |
| CPU Usage | Proxy overhead | Minimal |
| Network Traffic | Doubled | Direct |

## Debugging

### Enable Logging

```elixir
# In config/config.exs
config :logger, level: :debug
```

### Common Issues

1. **Connection Timeout**
   ```
   {:error, :timeout}
   ```
   - Check network connectivity
   - Verify firewall rules for port 5433

2. **SSL Handshake Failed**
   ```
   {:error, {:tls_alert, {:handshake_failure, _}}}
   ```
   - Check SSL certificate configuration
   - Verify TLS version compatibility

3. **Metadata Exchange Failed**
   ```
   {:error, {:metadata_exchange_failed, "Invalid token"}}
   ```
   - Verify OAuth token is valid
   - Check IAM permissions
   - Ensure IAM auth is enabled on cluster

4. **Token Fetch Failed**
   ```
   Failed to fetch OAuth token from Goth
   ```
   - Check Goth configuration
   - Verify Application Default Credentials
   - Ensure metadata service is accessible

## Protocol Analysis

### Captured Exchange

From Python connector analysis:

```python
# Request (293 bytes)
10 8F 02 0A 3C...  # Field 1: user_agent
10 02              # Field 2: auth_type = AUTO_IAM
1A FE 01 79 61...  # Field 3: oauth2_token

# Response (6 bytes)  
08 01              # Field 1: response_code = OK
```

### Protobuf Wire Types

- Type 0 (Varint): auth_type, response_code
- Type 2 (Length-delimited): user_agent, oauth2_token, error

### Field Tags

Request:
- Field 1 (tag 10): user_agent
- Field 2 (tag 16): auth_type
- Field 3 (tag 26): oauth2_token

Response:
- Field 1 (tag 08): response_code
- Field 2 (tag 18): error