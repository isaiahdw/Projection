import Config

config :logger, :default_formatter, metadata: [:sid, :rev, :screen]
