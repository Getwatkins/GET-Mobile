GET Mobile v68

Result of v67 testing (real device log): with parameters_3e_S50_core14.csv at 2 ms
frame spacing, HSL setup was acknowledged and polling ran (~5 Hz with 100 ms poll
delay). Replies decode to sensible values (idle ~1100 rpm, coolant 96 C, MAP 33-42 kPa).
The full 68-parameter S50 file never gets an acknowledgement, at any spacing, so the
ECU has a limit somewhere between 14 and 68 parameters. The first setup attempt also
sometimes failed with an identical second attempt succeeding.

Changes
- Setup is retried once automatically (same list, 0.5 s later) if the first attempt
  gets no acknowledgement. Final failure now says how many channels / bytes were sent.
- Frame spacing default is now 2 ms (the value that worked). Picker unchanged.
- Setup acknowledgement timeout 15 s -> 10 s per attempt.
- The file info line now shows the setup request size in bytes.
- New bundled bisect files (core14 + more S50 parameters, file order):
    file                              params  request  reply
    parameters_3e_S50_core14.csv        14       79      34   (known good)
    parameters_3e_S50_test20.csv        20      109      43
    parameters_3e_S50_test28.csv        28      149      57
    parameters_3e_S50_test36.csv        36      189      70
    parameters_3e_S50_test44.csv        44      229      81
    parameters_3e_S50_test52.csv        52      269      96
    parameters_3e_S50_test60.csv        60      309     109
    parameters_3e_S50.csv               68      349     124   (fails)
  Delete the test files from Resources/HslParams once the limit is known.

Files changed: Model/HslLoggerSession.swift, Views/DatalogView.swift,
Resources/HslParams/parameters_3e_S50_test{20,28,36,44,52,60}.csv (new).
Not compiled locally; syntax-checked only.
