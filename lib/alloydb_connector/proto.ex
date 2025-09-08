defmodule AlloydbConnector.Proto do
  @moduledoc """
  Simplified Protocol Buffer implementation for AlloyDB metadata exchange.
  
  This implements just enough of the protobuf protocol to handle the
  MetadataExchangeRequest and MetadataExchangeResponse messages.
  """

  defmodule MetadataExchangeRequest do
    @moduledoc """
    MetadataExchangeRequest for AlloyDB authentication.
    
    Field numbers:
    1. user_agent (string)
    2. auth_type (enum)
    3. oauth2_token (string)
    """
    
    defstruct [:user_agent, :auth_type, :oauth2_token]
    
    @auth_type_unspecified 0
    @auth_type_db_native 1
    @auth_type_auto_iam 2
    
    def encode(%__MODULE__{} = msg) do
      use Bitwise
      
      # Convert auth_type atom to integer
      auth_type_value = case msg.auth_type do
        :AUTH_TYPE_UNSPECIFIED -> @auth_type_unspecified
        :DB_NATIVE -> @auth_type_db_native
        :AUTO_IAM -> @auth_type_auto_iam
        _ -> @auth_type_unspecified
      end
      
      # Build protobuf message manually
      # Field 1: user_agent (string) - tag = (1 << 3) | 2 = 10
      # Field 2: auth_type (enum) - tag = (2 << 3) | 0 = 16
      # Field 3: oauth2_token (string) - tag = (3 << 3) | 2 = 26
      
      parts = []
      
      # Add user_agent if present
      parts = if msg.user_agent && msg.user_agent != "" do
        user_agent_bytes = msg.user_agent
        parts ++ [
          <<10>>,  # Field 1, wire type 2 (length-delimited)
          encode_varint(byte_size(user_agent_bytes)),
          user_agent_bytes
        ]
      else
        parts
      end
      
      # Add auth_type
      parts = parts ++ [
        <<16>>,  # Field 2, wire type 0 (varint)
        encode_varint(auth_type_value)
      ]
      
      # Add oauth2_token if present
      parts = if msg.oauth2_token && msg.oauth2_token != "" do
        token_bytes = msg.oauth2_token
        parts ++ [
          <<26>>,  # Field 3, wire type 2 (length-delimited)
          encode_varint(byte_size(token_bytes)),
          token_bytes
        ]
      else
        parts
      end
      
      IO.iodata_to_binary(parts)
    end
    
    defp encode_varint(n) when n < 128, do: <<n>>
    defp encode_varint(n) do
      use Bitwise
      <<1::1, band(n, 0x7F)::7>> <> encode_varint(bsr(n, 7))
    end
  end
  
  defmodule MetadataExchangeResponse do
    @moduledoc """
    MetadataExchangeResponse from AlloyDB.
    
    Field numbers:
    1. response_code (enum)
    2. error (string)
    """
    
    defstruct [:response_code, :error]
    
    @response_code_unspecified 0
    @response_code_ok 1
    @response_code_error 2
    
    def decode(bytes) do
      decode_fields(bytes, %__MODULE__{})
    end
    
    defp decode_fields(<<>>, acc), do: acc
    defp decode_fields(bytes, acc) do
      {field_num, wire_type, rest} = decode_tag(bytes)
      
      case {field_num, wire_type} do
        {1, 0} ->
          # response_code (varint)
          {value, rest} = decode_varint(rest)
          response_code = case value do
            @response_code_ok -> :OK
            @response_code_error -> :ERROR
            _ -> :RESPONSE_CODE_UNSPECIFIED
          end
          decode_fields(rest, %{acc | response_code: response_code})
          
        {2, 2} ->
          # error (string)
          {str, rest} = decode_string(rest)
          decode_fields(rest, %{acc | error: str})
          
        _ ->
          # Skip unknown fields
          {_value, rest} = skip_field(wire_type, rest)
          decode_fields(rest, acc)
      end
    end
    
    defp decode_tag(<<byte, rest::binary>>) do
      use Bitwise
      wire_type = band(byte, 0x07)
      field_num = bsr(byte, 3)
      
      if field_num == 0 do
        # Extended field number (not used in our case)
        raise "Extended field numbers not supported"
      else
        {field_num, wire_type, rest}
      end
    end
    
    defp decode_varint(bytes), do: decode_varint(bytes, 0, 0)
    
    defp decode_varint(<<0::1, value::7, rest::binary>>, acc, shift) do
      use Bitwise
      {bor(acc, bsl(value, shift)), rest}
    end
    defp decode_varint(<<1::1, value::7, rest::binary>>, acc, shift) do
      use Bitwise
      decode_varint(rest, bor(acc, bsl(value, shift)), shift + 7)
    end
    
    defp decode_string(bytes) do
      {length, rest} = decode_varint(bytes)
      <<str::binary-size(length), rest::binary>> = rest
      {str, rest}
    end
    
    defp skip_field(0, bytes) do
      # Varint
      decode_varint(bytes)
    end
    defp skip_field(2, bytes) do
      # Length-delimited
      {length, rest} = decode_varint(bytes)
      <<_skipped::binary-size(length), rest::binary>> = rest
      {nil, rest}
    end
    defp skip_field(_, bytes) do
      # Unknown wire type, can't skip safely
      raise "Unknown wire type"
    end
  end
end