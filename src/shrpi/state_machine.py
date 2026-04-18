#!/usr/bin/env python3
import time
from subprocess import check_call
import logging
from i2c import SHRPiDevice

import sys
import dbus
import dbus.service
import os

# import victron dbus mainloop and GLib to run the mainloop with event based dbus communication
from dbus.mainloop.glib import DBusGMainLoop
from gi.repository import GLib # for Python 3

# victron package used to report the states and voltages as dbus signals
sys.path.insert(1, os.path.join(os.path.dirname(__file__), '/opt/victronenergy/dbus-modem'))
from vedbus import VeDbusService
from settingsdevice import SettingsDevice

class SystemBus(dbus.bus.BusConnection):
    def __new__(cls):
        return dbus.bus.BusConnection.__new__(cls, dbus.bus.BusConnection.TYPE_SYSTEM)

class SessionBus(dbus.bus.BusConnection):
    def __new__(cls):
        return dbus.bus.BusConnection.__new__(cls, dbus.bus.BusConnection.TYPE_SESSION)

def dbusconnection():
    return SessionBus() if 'DBUS_SESSION_BUS_ADDRESS' in os.environ else SystemBus()

class StateMachine:
    def __init__(
            self,
            shrpi_device: SHRPiDevice,
            blackout_time_limit: float,
            blackout_voltage_limit: float,
            dry_run: bool = False,
            poweroff: str = "/sbin/poweroff"):
        self.logger = logging.getLogger(__name__) # create logger
        self.logger.info("Initializing state machine with the following parameters:")
        self.logger.info(f"  - shrpi_device: {shrpi_device}")
        self.logger.info(f"  - blackout_time_limit: {blackout_time_limit}")
        self.logger.info(f"  - blackout_voltage_limit: {blackout_voltage_limit}")
        self.logger.info(f"  - dry_run: {dry_run}")
        self.logger.info(f"  - poweroff: {poweroff}")

        self.shrpi_device = shrpi_device
        self.blackout_time_limit = blackout_time_limit
        self.blackout_voltage_limit = blackout_voltage_limit
        self.dry_run = dry_run
        self.poweroff = poweroff
        self.state = "START"
        self.blackout_time = 0.0

    def run(self):
        self.logger.info(">>>>>>>>>>>>>>>> Starting state machine <<<<<<<<<<<<<<<<")
        DBusGMainLoop(set_as_default=True)
        self.dbusservice = self.create_service(
            self.shrpi_device.hardware_version(),
            self.shrpi_device.firmware_version(),
        )
        GLib.timeout_add(1000, self.check_state)
        self._mainloop = GLib.MainLoop()
        self.logger.info('Connected to dbus, and switching over to GLib.MainLoop() (= event based)')
        self._mainloop.run()

    def stop(self):
        self.logger.info("Stopping state machine")
        if hasattr(self, '_mainloop'):
            self._mainloop.quit()

    def create_service(self, hwVersion, fwVersion):
        servicename = "com.victronenergy.sailorhat"
        connection = dbusconnection()
        self.logger.info(f"Creating dbus service {servicename} with connection {connection}")

        # register=False: add all paths before publishing to dbus, per Victron dbus-api convention
        svc = VeDbusService(servicename, connection, register=False)

        svc.add_mandatory_paths(
            processname=__file__,
            processversion='1.0',
            connection='i2c_rpi',
            deviceinstance=0,
            productid=0,
            productname='Sailor Hat for Raspberry Pi',
            firmwareversion=fwVersion,
            hardwareversion=hwVersion,
            connected=1,
        )
        svc.add_path('/Serial', '')
        svc.add_path('/State', 'Not started', writeable=True)
        svc.add_path('/VoltageIn', 0, writeable=True)
        svc.add_path('/CurrentIn', 0, writeable=True)
        svc.add_path('/ShutdownCountdown', 0, writeable=True)
        svc.add_path('/BlackoutTimeLimit', self.blackout_time_limit, writeable=True, onchangecallback=self.handle_changed_value)

        settingsList = {'BlackoutTimeLimit': ['/Settings/Sailorhat/BlackoutTimeLimit', self.blackout_time_limit, 1, 600]}
        self.DbusSettings = SettingsDevice(bus=dbus.SystemBus(), supportedSettings=settingsList, timeout=10, eventCallback=self.handle_changed_value)

        svc.register()
        self.logger.info(f"Created dbus service {servicename}")
        return svc
    
    # Values changed in the GUI need to be updated in the settings
    # Without this changes made through the GUI change the dBusObject but not the persistent setting
    def handle_changed_value(self, setting, old, new):
        # The callback to the handle value changes has been modified by using an anonymouse function (lambda)
        # the callback is declared each time a path is added see example here
        # self.add_path(path, 0, writeable=True, onchangecallback = lambda x,y: handle_changed_value(setting,x,y) )
        logging.info(f"Value changed for {setting} from {old} to {new}")
        return True

    def check_state(self):
        try:
            dcin_voltage = self.shrpi_device.dcin_voltage()
            dcin_current = self.shrpi_device.input_current()
            blackoutTimeLimit = self.DbusSettings['BlackoutTimeLimit']

            if self.state == "START":
                self.shrpi_device.set_watchdog_timeout(10)
                self.state = "OK"
            elif self.state == "OK":
                if dcin_voltage < self.blackout_voltage_limit:
                    self.logger.warning(f"Detected blackout, shutting down in {blackoutTimeLimit} s unless power resumes")
                    self.blackout_time = time.time()
                    self.state = "BLACKOUT"
            elif self.state == "BLACKOUT":
                if dcin_voltage > self.blackout_voltage_limit:
                    self.logger.info("Power resumed")
                    self.state = "OK"
                elif time.time() - self.blackout_time > blackoutTimeLimit:
                    self.logger.warning(f"Blacked out for {blackoutTimeLimit} s, shutting down")
                    self.state = "SHUTDOWN"
            elif self.state == "SHUTDOWN":
                if self.dry_run:
                    self.logger.warning(f"Would execute {self.poweroff}")
                else:
                    self.shrpi_device.request_shutdown()
                    self.logger.info(f"Executing {self.poweroff}")
                    check_call([self.poweroff])
                self.state = "DEAD"
            elif self.state == "DEAD":
                pass

            self.dbusservice['/State'] = self.state
            self.dbusservice['/VoltageIn'] = dcin_voltage
            self.dbusservice['/CurrentIn'] = dcin_current
            self.dbusservice['/ShutdownCountdown'] = blackoutTimeLimit - (time.time() - self.blackout_time) if self.state == "BLACKOUT" else 0

        except OSError as e:
            self.logger.warning(f"I2C error (will retry next tick): {e}")

        return True  # always keep the timer alive
