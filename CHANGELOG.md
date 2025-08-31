# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.3.0] - 2025-01-27

### Added
- Backup size reporting with Tarsnap archive statistics
- Duration tracking for database dumps, Tarsnap uploads, and total backup time
- Enhanced error details with timestamps and specific failure context
- Performance metrics in backup completion logs
- Compression ratio reporting (original → compressed size)
- Human-readable file size formatting
- Comprehensive backup statistics in email notifications

### Improved
- Email notifications now include timing and size statistics
- Error notifications provide detailed timestamps and failure reasons
- Better monitoring and troubleshooting capabilities
- Enhanced logging with performance insights

## [1.2.0] - 2025-01-27

### Added
- Interactive restore wizard with `--restore` flag
- Failproof restore functionality with multiple safety layers
- Automatic backup of existing site before restore
- Atomic restore operations with automatic rollback on failure
- WordPress installation validation after restore
- Dry run mode for testing restore without changes
- Comprehensive restore logging with audit trails
- Pagination support for browsing older backups
- Database connectivity testing before restore
- Permission and ownership verification after restore
- Enhanced confirmation process requiring 'RESTORE' input

### Security
- Pre-restore validation including disk space and archive integrity checks
- Secure staging area for atomic file operations
- Complete rollback capability on any restore failure

### Documentation
- Updated README with restore instructions and usage examples
- Added restore wizard workflow documentation
- Updated limitations section to reflect new capabilities

## [1.1.0] - 2025-01-27

### Improved
- Enhanced configuration file loading with intelligent priority system
- Automatic config discovery: `/etc/` first, then script directory, then defaults
- Simplified usage - no config path required for standard installations
- Updated documentation to reflect new configuration loading behavior

## [1.0.0] - 2025-08-26

### Added
- WordPress site auto-discovery and backup automation
- Database credential extraction from wp-config.php files
- Secure temporary file handling with proper cleanup
- Comprehensive error handling and logging system
- Email notifications for backup completion and errors
- Three retention schemes: Simple, GFS (Grandfather-Father-Son), and Manual
- GFS retention with hourly/daily/weekly/monthly/yearly tiers
- Manual retention mode for full user control
- External configuration file support (wordpress-tarsnap-backups.conf)
- Flexible configuration loading with fallback defaults
- Pre-flight checks for required commands and disk space
- Input validation and sanitization for security
- Configurable site exclusion list
- Per-site and main logging with timestamps
- Tarsnap compatibility improvements (TARSNAP_KEYFILE environment variable)
- Production validation checks for retention configuration and connectivity

### Security
- Secure credential handling with temporary files (600 permissions)
- Input sanitization to prevent command injection
- ReDoS-safe regex patterns
- Automatic cleanup of sensitive temporary files
- Timeout protection for long-running operations

### Documentation
- Comprehensive README with installation and configuration instructions
- Security documentation outlining protection measures
- Retention policy explanations with examples
- Troubleshooting guide
- Restore instructions with examples