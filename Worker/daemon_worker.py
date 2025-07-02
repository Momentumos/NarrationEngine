#!/usr/bin/env python3
"""
Daemon wrapper for the Orpheus Worker System
Provides daemon functionality with proper signal handling, logging, and process management
"""

import os
import sys
import signal
import time
import asyncio
import logging
import argparse
from pathlib import Path
from datetime import datetime
from worker_system import WorkerManager, WorkerConfig

class WorkerDaemon:
    """Daemon wrapper for the worker system"""
    
    def __init__(self, pidfile, logfile=None, working_dir=None):
        self.pidfile = pidfile
        self.logfile = logfile or 'worker_daemon.log'
        self.working_dir = working_dir or os.getcwd()
        self.manager = None
        self.running = False
        
    def daemonize(self):
        """Daemonize the current process"""
        try:
            # First fork
            pid = os.fork()
            if pid > 0:
                # Exit first parent
                sys.exit(0)
        except OSError as e:
            sys.stderr.write(f"Fork #1 failed: {e}\n")
            sys.exit(1)
        
        # Decouple from parent environment
        os.chdir(self.working_dir)
        os.setsid()
        os.umask(0)
        
        try:
            # Second fork
            pid = os.fork()
            if pid > 0:
                # Exit second parent
                sys.exit(0)
        except OSError as e:
            sys.stderr.write(f"Fork #2 failed: {e}\n")
            sys.exit(1)
        
        # Redirect standard file descriptors
        sys.stdout.flush()
        sys.stderr.flush()
        
        # Redirect stdin, stdout, stderr to /dev/null
        with open('/dev/null', 'r') as f:
            os.dup2(f.fileno(), sys.stdin.fileno())
        
        # Redirect stdout and stderr to log file
        with open(self.logfile, 'a+') as f:
            os.dup2(f.fileno(), sys.stdout.fileno())
            os.dup2(f.fileno(), sys.stderr.fileno())
        
        # Write pidfile
        pid = str(os.getpid())
        with open(self.pidfile, 'w+') as f:
            f.write(f"{pid}\n")
    
    def setup_logging(self):
        """Setup logging for daemon mode"""
        log_format = '%(asctime)s - %(name)s - %(levelname)s - %(message)s'
        logging.basicConfig(
            level=logging.INFO,
            format=log_format,
            handlers=[
                logging.FileHandler(self.logfile),
                logging.StreamHandler()
            ]
        )
        
        # Log daemon startup
        logger = logging.getLogger(__name__)
        logger.info("=" * 50)
        logger.info("Orpheus Worker Daemon Starting")
        logger.info(f"PID: {os.getpid()}")
        logger.info(f"Working Directory: {self.working_dir}")
        logger.info(f"Log File: {self.logfile}")
        logger.info(f"PID File: {self.pidfile}")
        logger.info("=" * 50)
    
    def setup_signal_handlers(self):
        """Setup signal handlers for graceful shutdown"""
        def signal_handler(signum, frame):
            logger = logging.getLogger(__name__)
            logger.info(f"Received signal {signum}, shutting down gracefully...")
            self.stop()
        
        signal.signal(signal.SIGTERM, signal_handler)
        signal.signal(signal.SIGINT, signal_handler)
        signal.signal(signal.SIGHUP, signal_handler)
    
    def start(self):
        """Start the daemon"""
        # Check for existing pidfile
        if os.path.exists(self.pidfile):
            with open(self.pidfile, 'r') as f:
                pid = int(f.read().strip())
            
            # Check if process is still running
            try:
                os.kill(pid, 0)
                print(f"Daemon already running with PID {pid}")
                sys.exit(1)
            except OSError:
                # Process not running, remove stale pidfile
                os.remove(self.pidfile)
        
        # Daemonize
        self.daemonize()
        
        # Setup logging and signal handlers
        self.setup_logging()
        self.setup_signal_handlers()
        
        # Start the worker system
        self.run_worker_system()
    
    def stop(self):
        """Stop the daemon"""
        self.running = False
        if self.manager:
            self.manager.stop()
        
        # Remove pidfile
        if os.path.exists(self.pidfile):
            os.remove(self.pidfile)
    
    def restart(self):
        """Restart the daemon"""
        self.stop_daemon()
        time.sleep(1)
        self.start()
    
    def stop_daemon(self):
        """Stop daemon by PID"""
        if not os.path.exists(self.pidfile):
            print("Daemon not running (no pidfile found)")
            return
        
        with open(self.pidfile, 'r') as f:
            pid = int(f.read().strip())
        
        try:
            # Send SIGTERM
            os.kill(pid, signal.SIGTERM)
            
            # Wait for process to terminate
            for _ in range(30):  # Wait up to 30 seconds
                try:
                    os.kill(pid, 0)
                    time.sleep(1)
                except OSError:
                    break
            else:
                # Force kill if still running
                print("Process didn't terminate gracefully, force killing...")
                os.kill(pid, signal.SIGKILL)
            
            print(f"Daemon stopped (PID {pid})")
            
        except OSError as e:
            print(f"Error stopping daemon: {e}")
        
        # Remove pidfile
        if os.path.exists(self.pidfile):
            os.remove(self.pidfile)
    
    def status(self):
        """Check daemon status"""
        if not os.path.exists(self.pidfile):
            print("Daemon is not running")
            return False
        
        with open(self.pidfile, 'r') as f:
            pid = int(f.read().strip())
        
        try:
            os.kill(pid, 0)
            print(f"Daemon is running (PID {pid})")
            
            # Show additional info if log file exists
            if os.path.exists(self.logfile):
                stat = os.stat(self.logfile)
                last_modified = datetime.fromtimestamp(stat.st_mtime)
                print(f"Log file: {self.logfile}")
                print(f"Last activity: {last_modified}")
                
                # Show last few log lines
                try:
                    with open(self.logfile, 'r') as f:
                        lines = f.readlines()
                        if lines:
                            print("\nLast 5 log entries:")
                            for line in lines[-5:]:
                                print(f"  {line.strip()}")
                except Exception:
                    pass
            
            return True
        except OSError:
            print(f"Daemon not running (stale pidfile with PID {pid})")
            os.remove(self.pidfile)
            return False
    
    def run_worker_system(self):
        """Run the worker system"""
        logger = logging.getLogger(__name__)
        self.running = True
        
        try:
            # Load configuration
            config = WorkerConfig()
            
            # Validate configuration
            required_vars = [
                'API_BASE_URL', 'SERVER_TO_SERVER_API_KEY', 
                'AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY', 'S3_BUCKET'
            ]
            
            missing_vars = []
            for var in required_vars:
                if not getattr(config, var.lower(), None):
                    missing_vars.append(var)
            
            if missing_vars:
                logger.error(f"Missing required environment variables: {', '.join(missing_vars)}")
                logger.error("Please check your .env file")
                return
            
            # Create and run worker manager
            self.manager = WorkerManager(config)
            logger.info("Starting worker system...")
            
            # Run the async worker system
            asyncio.run(self.manager.run())
            
        except Exception as e:
            logger.error(f"Worker system error: {e}")
        finally:
            logger.info("Worker system stopped")
            self.running = False

def main():
    parser = argparse.ArgumentParser(description='Orpheus Worker Daemon')
    parser.add_argument('action', choices=['start', 'stop', 'restart', 'status'],
                       help='Daemon action')
    parser.add_argument('--pidfile', default='worker_daemon.pid',
                       help='PID file path (default: worker_daemon.pid)')
    parser.add_argument('--logfile', default='worker_daemon.log',
                       help='Log file path (default: worker_daemon.log)')
    parser.add_argument('--workdir', default=None,
                       help='Working directory (default: current directory)')
    
    args = parser.parse_args()
    
    # Convert to absolute paths
    pidfile = os.path.abspath(args.pidfile)
    logfile = os.path.abspath(args.logfile)
    workdir = os.path.abspath(args.workdir) if args.workdir else os.getcwd()
    
    daemon = WorkerDaemon(pidfile, logfile, workdir)
    
    if args.action == 'start':
        print(f"Starting Orpheus Worker Daemon...")
        print(f"PID file: {pidfile}")
        print(f"Log file: {logfile}")
        print(f"Working directory: {workdir}")
        daemon.start()
    elif args.action == 'stop':
        print("Stopping Orpheus Worker Daemon...")
        daemon.stop_daemon()
    elif args.action == 'restart':
        print("Restarting Orpheus Worker Daemon...")
        daemon.restart()
    elif args.action == 'status':
        daemon.status()

if __name__ == "__main__":
    main()
