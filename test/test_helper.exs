Path.wildcard("test_support/**/*.{ex,exs}")
|> Enum.sort()
|> Enum.each(&Code.require_file/1)

ExUnit.start()
