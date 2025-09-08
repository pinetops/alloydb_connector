# AlloyDB Connector for Elixir

A pure Elixir implementation of the AlloyDB metadata exchange protocol, allowing direct IAM authentication without the auth proxy.

## Overview

This library implements the same protocol that the AlloyDB auth proxy uses internally, enabling direct connections to AlloyDB instances on port 5433. It performs the metadata exchange with OAuth tokens for IAM authentication, then hands off the authenticated socket to Postgrex for standard PostgreSQL communication.

## The Key Discovery

AlloyDB exposes two ports:
- **Port 5432**: Standard PostgreSQL (recognizes IAM users but rejects OAuth tokens)  
- **Port 5433**: Metadata exchange protocol endpoint (what the auth proxy connects to)

The Python and Go connectors don't bypass the protocol - they implement it themselves! This Elixir implementation does the same.

## How It Works

```
┌─────────────┐      ┌──────────────────┐      ┌─────────────┐
│   Postgrex  │──────│ AlloyDB Connector│──────│   AlloyDB   │
│             │      │                  │      │  Port 5433  │
└─────────────┘      └──────────────────┘      └─────────────┘
       │                      │                       │
       ▼                      ▼                       ▼
  PostgreSQL            Metadata Exchange        Accepts OAuth
   Protocol               Protocol                  Tokens
```

The connector:
1. Connects to AlloyDB on port 5433
2. Performs SSL/TLS handshake
3. Sends a Protocol Buffer `MetadataExchangeRequest` with OAuth token
4. Receives `MetadataExchangeResponse`
5. On success, the socket is ready for PostgreSQL protocol
6. Passes the authenticated socket to Postgrex

## Installation

Add to your `mix.exs`:

```elixir
def deps do
  [
    {:alloydb_connector, github: "your-org/alloydb_connector"},
    {:goth, github: "pinetops/goth", branch: "alloydb-support"},
    {:postgrex, github: "pinetops/postgrex", branch: "iam-support"}
  ]
end
```

