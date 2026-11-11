ExUnit.start()

ExUnit.after_suite(fn _ ->
  dir = Application.get_env(:sismo, :data_dir)

  if is_binary(dir) and String.starts_with?(Path.expand(dir), Path.expand(System.tmp_dir!())) do
    File.rm_rf(dir)
  end
end)
