{
  lib,
  runCommand,
}:

runCommand "orca-cpp-port-${lib.replaceStrings [ "." ] [ "-" ] "0.5.0-dev"}"
  {
    meta = {
      description = "Orca (C++ port scaffolding)";
      license = lib.licenses.mpl20;
    };
  }
  ''
    touch "$out"
  ''
