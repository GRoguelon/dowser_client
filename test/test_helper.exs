Application.ensure_started(:inets)
Application.ensure_started(:ssl)

# Two kinds of log are expected noise here: OTP's `ssl` notices from the TLS
# tests, which deliberately fail handshakes, and `Dowser.Client.HTTP`'s debug
# line when it rewrites a GET carrying a body into a POST. Capturing swallows
# them for a passing test and still prints them for a failing one.
ExUnit.start(capture_log: true)
