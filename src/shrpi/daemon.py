
import argparse
import logging
import logging.handlers
from signal import pause
from subprocess import check_call
import signal
import sys
import time
from shrpi.const import BLACKOUT_TIME_LIMIT, BLACKOUT_VOLTAGE_LIMIT, I2C_ADDR, I2C_BUS

from shrpi.shrpi_device import SHRPiDevice


def parse_arguments():
    parser = argparse.ArgumentParser()
    parser.add_argument("--i2c-bus", type=int, default=I2C_BUS)
    parser.add_argument("--i2c-addr", type=int, default=I2C_ADDR)
    parser.add_argument(
        "--allowed-blackout-time", type=float, default=BLACKOUT_TIME_LIMIT
    )
    parser.add_argument("-n", default=False, action="store_true")

    return parser.parse_args()


def run_state_machine(logger, dev, allowed_blackout_time, pretend_only=False):
    state = "START"
    blackout_time = 0

    # Poll hardware and firmware versions. This will set SHRPiDevice in the
    # correct mode.
    hw_version = dev.hardware_version()
    fw_version = dev.firmware_version()

    logger.info(
        "SH-RPi device detected; HW version %s, FW version %s", hw_version, fw_version
    )

    while True:
        # TODO: Provide facilities for reporting the states and voltages
        # en5v_state = dev.en5v_state()
        # dev_state = dev.state()
        dcin_voltage = dev.dcin_voltage()
        # supercap_voltage = dev.supercap_voltage()

        if state == "START":
            dev.set_watchdog_timeout(10)
            if dcin_voltage < BLACKOUT_VOLTAGE_LIMIT:
                logger.warn("Detected blackout on startup, ignoring")
            state = "OK"
        elif state == "OK":
            if dcin_voltage < BLACKOUT_VOLTAGE_LIMIT:
                logger.warn("Detected blackout")
                blackout_time = time.time()
                state = "BLACKOUT"
        elif state == "BLACKOUT":
            if dcin_voltage > BLACKOUT_VOLTAGE_LIMIT:
                logger.info("Power resumed")
                state = "OK"
            elif time.time() - blackout_time > allowed_blackout_time:
                # didn't get power back in time
                logger.warn(
                    "Blacked out for {} s, shutting down".format(allowed_blackout_time)
                )
                state = "SHUTDOWN"
        elif state == "SHUTDOWN":
            if pretend_only:
                logger.warn("Would execute /sbin/poweroff")
            else:
                # inform the hat about this sad state of affairs
                dev.request_shutdown()
                check_call(["sudo", "/sbin/poweroff"])
            state = "DEAD"
        elif state == "DEAD":
            # just wait for the inevitable
            pass
        time.sleep(0.1)


def main():
    args = parse_arguments()

    i2c_bus = args.i2c_bus
    i2c_addr = args.i2c_addr

    # TODO: should test that the device is responding and has correct firmware

    dev = SHRPiDevice(i2c_bus, i2c_addr)

    allowed_blackout_time = args.allowed_blackout_time

    logger = logging.getLogger("sh_rpi")
    handler = logging.handlers.SysLogHandler(address="/dev/log")
    formatter = logging.Formatter("%(name)s[%(process)d]: %(message)s")
    handler.setFormatter(formatter)
    logger.addHandler(handler)
    logger.setLevel(logging.INFO)

    def cleanup(signum, frame):
        logger.info("Disabling SH-RPi watchdog")
        dev.set_watchdog_timeout(0)
        sys.exit(0)

    signal.signal(signal.SIGINT, cleanup)
    signal.signal(signal.SIGTERM, cleanup)

    run_state_machine(logger, dev, allowed_blackout_time)


if __name__ == "__main__":
    main()
