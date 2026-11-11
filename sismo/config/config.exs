import Config
config :sismo, data_dir: "data"

if config_env() == :test do
  config :sismo, pbkdf2_iterations: 100

  config :sismo,
    data_dir: Path.join(System.tmp_dir!(), "sismo_cli_#{System.os_time(:millisecond)}")
end
