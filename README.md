NTP Client Manager

A lightweight, offline-friendly Linux NTP Client Management and Troubleshooting TUI built with Bash for systems using "systemd-timesyncd".

NTP Client Manager provides a centralized terminal interface for configuring NTP servers, testing connectivity, monitoring synchronization, troubleshooting time-related issues, managing backups, and generating diagnostic information.

Instead of managing "systemd-timesyncd" through multiple commands and configuration files, NTP Client Manager brings the most important NTP client administration and troubleshooting operations into a single interactive interface.

---

Features

Time & Timezone

- View current system time
- View UTC time
- View local timezone
- Manage system timezone
- View RTC information
- Inspect time synchronization state

NTP Configuration

- View current NTP configuration
- Configure NTP servers
- Configure fallback NTP servers
- Validate NTP configuration
- Export configuration
- Import configuration
- Preview configuration changes before applying them

NTP Server Management

- Add NTP servers
- Remove configured NTP servers
- Test configured NTP servers
- Test multiple NTP servers
- Verify NTP communication
- Check NTP server reachability
- Review server response information

NTP server testing is designed around:

TEST → REVIEW → APPLY

This helps prevent invalid or unreachable NTP servers from being blindly added to the system configuration.

Synchronization Management

- View synchronization status
- Enable NTP synchronization
- Disable NTP synchronization
- Force/restart synchronization
- View current synchronization information
- Monitor synchronization state

systemd-timesyncd Service Management

The tool provides a dedicated interface for managing the "systemd-timesyncd" service:

- Start
- Stop
- Restart
- View service status
- Inspect service-related events

Live NTP Monitoring

The monitoring interface provides information such as:

- Current synchronization state
- Current NTP server
- Service state
- Configured NTP servers
- NTP server reachability
- Offset
- Root distance
- Poll interval
- Last synchronization information

The monitoring refresh interval can be configured from the application settings.

Logs & Troubleshooting

NTP Client Manager integrates with the system journal to help investigate NTP problems.

Available monitoring options include:

- Recent NTP events
- Failed NTP events
- Live log monitoring
- NTP synchronization events
- Timeout events
- Unreachable server events
- Invalid configuration events
- Denied/error events
- Application monitoring history

The tool uses "journalctl" to inspect "systemd-timesyncd" activity.

Diagnostics

The diagnostics section provides tools for troubleshooting the NTP client environment.

Available functions include:

- System detection
- Configuration validation
- Synchronization information
- Diagnostic report generation

Diagnostic reports are designed to provide useful troubleshooting information without intentionally including credentials or secrets.

Backup & Restore

Before important configuration changes, NTP Client Manager can create backups of its managed configuration.

Available operations include:

- View backups
- Create backup
- Restore backup
- Delete old backups

Backup retention can be configured from the application settings.

Import & Export

Configuration can be exported and imported through the TUI.

Import supports several modes:

- Complete configuration
- NTP-only configuration
- Timezone-only configuration
- NTP + timezone configuration
- Preview mode

The import workflow can validate and review the configuration before applying changes.

Where applicable, NTP servers can also be tested before the imported configuration is applied.

The general workflow is:

IMPORT → PARSE → VALIDATE → REVIEW → TEST → BACKUP → APPLY → RESTART → VERIFY

Offline / On-Premises Friendly

NTP Client Manager is designed for environments where Internet access may be restricted or unavailable.

It does not require a cloud service or external management platform.

This makes it suitable for:

- On-premises infrastructure
- Isolated environments
- Offline environments
- Server administration
- Network infrastructure
- Lab environments
- Infrastructure troubleshooting

TUI With Bash Fallback

The application provides a terminal-based interactive interface.

When supported TUI utilities such as "whiptail" or "dialog" are available, they can be used for the interactive interface.

A Pure Bash fallback is also available when those utilities are not installed.

---

Screens / Main Menu

The main interface provides access to:

NTP Client Manager

1. Overview
2. Time & Timezone
3. NTP Configuration
4. NTP Servers
5. Synchronization
6. Service
7. Monitoring
8. Diagnostics
9. Export Configuration
10. Import Configuration
11. Backup / Restore
12. Settings
13. Exit

The exact interface may evolve as the project develops.

---

Architecture

NTP Client Manager is intentionally lightweight.

The project is currently implemented as a standalone Bash application and works primarily with native Linux/systemd components.

                  NTP Client Manager
                          |
                          v
                    Bash TUI Layer
                          |
        +-----------------+-----------------+
        |                 |                 |
        v                 v                 v
  systemd-timesyncd   systemctl        timedatectl
        |                 |                 |
        +-----------------+-----------------+
                          |
                          v
                     journalctl
                          |
                          v
                  Linux System / NTP

The application manages configuration through the system's "systemd-timesyncd" configuration rather than implementing its own NTP daemon.

---

Requirements

The following commands/utilities are required by the application:

- Bash
- systemctl
- timedatectl
- journalctl
- awk
- sed
- grep
- date
- getent

The target environment should have:

- Linux
- systemd
- "systemd-timesyncd"

Some read-only functionality may be available without root privileges, while configuration and system administration operations require appropriate administrative privileges.

---

Installation

Clone the repository:

git clone https://github.com/jafartavana01/NTPClientManager.git

Enter the project directory:

cd NTPClientManager

Make the script executable:

chmod +x ntp-manager.sh

Run it:

./ntp-manager.sh

For operations requiring administrative privileges:

sudo ./ntp-manager.sh

---

First Run

On startup, NTP Client Manager checks the environment and detects relevant system components.

The application checks for:

- Required commands
- systemd availability
- "systemd-timesyncd"
- Existing configuration
- Application directories

Administrative initialization is performed when required.

---

Configuration Locations

The application maintains its own application data separately from the native "systemd-timesyncd" configuration.

Important paths include:

/etc/ntp-manager
/var/log/ntp-manager
/var/backups/ntp-manager
/var/lib/ntp-manager

The native "systemd-timesyncd" configuration is located at:

/etc/systemd/timesyncd.conf

NTP Client Manager also uses a managed drop-in configuration:

/etc/systemd/timesyncd.conf.d/90-ntp-manager.conf

---

Security Considerations

NTP Client Manager is designed for local system administration and does not require an external management server.

The application also uses a restrictive default file creation mask:

umask 027

Diagnostic reports are designed to avoid intentionally exposing credentials or secrets.

Before applying significant configuration changes, the application can create a backup so that the previous state can be restored if necessary.

«Always review exported configuration and diagnostic information before sharing it outside your environment.»

---

Monitoring

The monitoring functionality can display information obtained from "systemd-timesyncd", including:

Synchronization State
Current NTP Server
Service State
Configured NTP Servers
Server Reachability
Offset
Root Distance
Poll Interval
Last Synchronization

This provides a convenient operational view without requiring administrators to manually combine several Linux commands.

---

Troubleshooting Workflow

A typical troubleshooting workflow can be:

1. Open NTP Client Manager
          |
          v
2. Check Overview
          |
          v
3. Check Time & Timezone
          |
          v
4. Check NTP Configuration
          |
          v
5. Test NTP Servers
          |
          v
6. Check Synchronization
          |
          v
7. Review Recent / Failed Events
          |
          v
8. Run Diagnostics
          |
          v
9. Apply Configuration if required
          |
          v
10. Verify Synchronization

This workflow is particularly useful when troubleshooting time synchronization problems on Linux servers.

---

Backup & Recovery Workflow

Configuration changes can follow this general process:

Current Configuration
        |
        v
      Backup
        |
        v
      Modify
        |
        v
      Apply
        |
        v
     Restart
        |
        v
      Verify
        |
   +----+----+
   |         |
 Success   Failure
   |         |
   v         v
  Done    Restore

---

Project Goals

The main goals of NTP Client Manager are:

- Simplify Linux NTP client administration
- Provide a practical troubleshooting interface
- Reduce repetitive command-line operations
- Make NTP configuration safer
- Provide visibility into synchronization status
- Support offline and on-premises environments
- Keep the tool lightweight and dependency-conscious
- Provide useful diagnostics without requiring a large management platform

The project is not intended to replace an NTP server or implement a new NTP protocol stack.

It is a management and troubleshooting tool for Linux NTP clients using "systemd-timesyncd".

---

Roadmap

Potential future improvements may include:

- Enhanced NTP server diagnostics
- More detailed synchronization history
- Additional monitoring metrics
- Improved terminal UI
- Additional Linux distribution support
- Configuration profiles
- Automated health checks
- Extended reporting
- Additional system time diagnostics
- Improved import/export compatibility
- More advanced NTP troubleshooting

---

Contributing

Contributions, bug reports, feature requests, and suggestions are welcome.

Before submitting a change:

1. Test the script on a supported Linux environment.
2. Avoid introducing unnecessary external dependencies.
3. Preserve compatibility with offline environments where possible.
4. Verify that configuration changes do not unintentionally modify unrelated system configuration.
5. Include relevant details when reporting problems.

---

Disclaimer

NTP Client Manager modifies system time synchronization configuration and interacts with system services.

Use appropriate privileges and test configuration changes in a controlled environment before deploying them to production systems.

The authors are not responsible for service interruption, incorrect time configuration, or other consequences resulting from improper use of the software.

---

License

This project is open source.

See the repository license file for the applicable license terms.

---

Author

Jafar Tavana

Network Engineer & Security Specialist

GitHub:

"https://github.com/jafartavana01"

---

Project

NTP Client Manager

A lightweight Linux NTP client management and troubleshooting tool for "systemd-timesyncd".

TEST → REVIEW → APPLY → VERIFY
