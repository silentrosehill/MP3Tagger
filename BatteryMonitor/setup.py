"""Build a standalone .app:  pip3 install py2app && python3 setup.py py2app
The app ends up in dist/Battery Monitor.app"""
from setuptools import setup

setup(
    app=["app.py"],
    name="Battery Monitor",
    options={"py2app": {
        "argv_emulation": False,
        "packages": ["rumps"],
        "plist": {
            "CFBundleName": "Battery Monitor",
            "CFBundleIdentifier": "local.batterymonitor",
            "LSUIElement": True,  # menu bar only, no Dock icon
        },
    }},
    setup_requires=["py2app"],
)
