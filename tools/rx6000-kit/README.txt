OpenNR RX 6000 test kit

This tests the new mochizuki NR network for RX 6000 cards (RX 6400 up to RX 6950 XT, and RDNA2
laptops and handhelds) before it goes into OpenNR. It checks four things on your card:
  - what your driver offers (the card, the driver version, the features the network needs);
  - that AMD's shader compiler builds every shader of the network (each one in its own process,
    so a compiler crash cannot take the test down);
  - that the picture is right: the network runs on a test picture at 1280x720 and 1920x1080 with
    both models, three times each, and every result is compared with the same picture made on an
    RX 9070 XT;
  - how fast it is: the network's time per frame and the time of each shader, with the GPU clock.

It does not install anything, and it does not touch your games, your drivers or their settings.
Everything stays inside this folder.

1. Unzip this folder anywhere (for example your Desktop). Keep about 1 GB free there.
2. Close games and other heavy programs.
3. Double-click run-test.bat.
   - If Windows says "Windows protected your PC" (SmartScreen), click "More info", then "Run anyway".
     The kit's programs are not signed, which is why Windows asks.
   - If Microsoft Defender or another antivirus removes or blocks a file from the "files" folder,
     the test cannot run. Allow the folder (or restore the file) and run it again, or just tell us.
     The test uses Windows' own rundll32.exe to compile the shaders in a separate process; some
     antivirus programs warn about that.
4. Wait. It takes about 10 to 20 minutes. The first time it downloads the two model files (about
   250 MB) from the same place the OpenNR installer uses, and the first run builds the network,
   which takes a few minutes. The GPU fans may spin up; that is normal. Every step has a time
   limit, so a step that hangs is stopped and the test goes on. Please leave the window open.
5. When it says "Done", send us the one file it names:
   OpenNR-RX6000-result-<date>.zip (next to run-test.bat; the folder opens by itself).
   It holds text logs, your card and driver names and two small pictures of the result. Nothing
   else from your PC.

If the window closes or the PC freezes, restart, then zip the "result" folder, send it and tell us
what happened.

You can delete the whole folder afterwards.
