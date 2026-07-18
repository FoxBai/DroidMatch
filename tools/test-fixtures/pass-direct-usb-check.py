#!/usr/bin/env python3

import os
import sys
from pathlib import Path


expected = ["--serial", os.environ["FAKE_SERIAL"]]
counter_path = os.environ.get("FAKE_DIRECT_USB_COUNTER")
if counter_path:
    counter = Path(counter_path)
    count = int(counter.read_text()) + 1 if counter.exists() else 1
    counter.write_text(str(count))
else:
    count = 0
fail_after = int(os.environ.get("FAKE_DIRECT_USB_FAIL_AFTER", "0"))
fail_stage = os.environ.get("FAKE_DIRECT_USB_FAIL_STAGE", "")
if (
    sys.argv[1:] != expected
    or os.environ.get("FAKE_DIRECT_USB_TOPOLOGY") == "hub"
    or (fail_after and count >= fail_after)
    or (fail_stage and os.environ.get("DROIDMATCH_DIRECT_USB_CHECK_STAGE") == fail_stage)
):
    raise SystemExit(1)
