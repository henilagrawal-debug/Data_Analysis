"""
Launch the ArduPilot Log Viewer web application.
Installs dependencies if needed, then starts the Flask server and opens a browser.
"""

import subprocess
import sys
import os
import webbrowser
import time
from pathlib import Path

WEB_DIR = Path(__file__).parent / 'web'
REQ_FILE = WEB_DIR / 'requirements.txt'
APP_FILE = WEB_DIR / 'app.py'
URL = 'http://127.0.0.1:5000'


def install_deps():
    """Install Python dependencies from requirements.txt if not already installed."""
    try:
        import flask, numpy, scipy  # noqa: F401
        return
    except ImportError:
        pass

    print("Installing dependencies...")
    subprocess.check_call([
        sys.executable, '-m', 'pip', 'install', '-r', str(REQ_FILE),
    ])
    print("Dependencies installed.\n")


def main():
    install_deps()

    print(f"Starting ArduPilot Log Viewer at {URL}")
    print("Press Ctrl+C to stop.\n")

    # Open browser after a short delay
    def open_browser():
        time.sleep(1.5)
        webbrowser.open(URL)

    import threading
    threading.Thread(target=open_browser, daemon=True).start()

    # Run Flask
    os.chdir(str(WEB_DIR))
    subprocess.call([sys.executable, str(APP_FILE)])


if __name__ == '__main__':
    main()
