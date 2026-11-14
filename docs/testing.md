# Testing

Install dependencies with `flutter pub get`, then run the same checks as CI:

```sh
make check-format
make lint
make test
```

The format check uses a 120-character line length. `make format` applies
formatting; `make lint-fix` applies Dart fixes. Neither is a read-only check.

## Backend feature interoperability

The integration test uses real DeskConn file, terminal, and TCP forwarding
handlers through the backend's local yamux application connection and an XConn
RPC bridge. It exercises both routed QUIC and direct WebRTC connections.

With a DeskConn checkout at `../deskconn`, Go and the published XConn native SDK
installed, build the local fixture:

```sh
(cd ../deskconn && go build -tags xconn_static \
  -o /tmp/deskconn-client-peer ./tests/client-peer)
```

From the mobile repository, run:

```sh
DESKCONN_STREAM_PEER=/tmp/deskconn-client-peer \
  flutter test test/core/rpc_features_integration_test.dart
```

Without `DESKCONN_STREAM_PEER`, the backend integration test is skipped. The
fixture uses local endpoints and temporary files; it does not require a cloud
account. It tests encrypted uploads/downloads, concurrent shells, forward/reverse
TCP tunnels, error handling, and cleanup. Real-device NAT traversal, Android
background behavior, and VPN still require separate testing.

See the [backend fixture documentation](https://github.com/xconnio/deskconn/blob/main/tests/client-peer/README.md)
for further setup details.
