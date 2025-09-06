# Contributing to WordPress Tarsnap Backups

Thank you for your interest in contributing to this project! We welcome contributions from the community.

## How to Contribute

### Reporting Issues
- Use the GitHub issue tracker to report bugs or request features
- Provide detailed information about your environment and the issue
- Include relevant log files or error messages

### Submitting Changes
1. Fork the repository
2. Create a feature branch (`git checkout -b feature/your-feature-name`)
3. Make your changes
4. Test your changes thoroughly in a non-production environment
5. Commit your changes with clear, descriptive messages
6. Push to your fork and submit a pull request

### Code Standards
- Follow existing code style and formatting
- Add comments for complex logic
- Quote all variable expansions in shell scripts
- Include error handling for new functionality
- Update documentation for any user-facing changes

### Testing
- Test all changes in a safe, non-production environment
- Verify that existing functionality still works
- Test edge cases and error conditions

### Documentation
- Update README.md if adding new features or changing usage
- Update CHANGELOG.md following the established format
- Include inline comments for complex code sections

## Development Setup

1. Clone the repository
2. Set up a test WordPress environment
3. Configure the script for your test environment
4. Test changes thoroughly before submitting

## Commit Message Format

This project follows the [Conventional Commits](https://www.conventionalcommits.org/) specification.

### Structure

```
<type>: <description> (v<version>)

- <detailed change 1>
- <detailed change 2>
- <detailed change 3>
- <additional context>
```

### Commit Types

- **`feat:`** - New features (triggers MINOR version bump)
- **`fix:`** - Bug fixes (triggers PATCH version bump)
- **`docs:`** - Documentation changes only
- **`refactor:`** - Code refactoring without behavior changes
- **`perf:`** - Performance improvements
- **`test:`** - Adding or updating tests
- **`chore:`** - Maintenance tasks, dependency updates

### Examples

```bash
feat: Add failproof restore wizard with comprehensive safety measures

- Interactive restore wizard with site/backup selection and pagination
- Atomic operations with automatic rollback on any failure
- Pre-restore validation (disk space, connectivity, archive integrity)
- Automatic backup of existing site and database before restore
- WordPress installation validation after restore
- Updated documentation and version bump to 1.2.0
```

```bash
fix: Resolve 'local' variable error in progress indicators (v1.4.1)

- Fixed 'local: can only be used in a function' error in background processes
- Removed incorrect local variable declarations from progress indicator loops
- Improved script reliability and bash compatibility
- Reordered changelog entries to show newest versions first
```

### Commit Guidelines

1. **Always include version** in parentheses for feat/fix commits
2. **Use bullet points** for detailed changes in commit body
3. **Keep first line under 72 characters**
4. **Use imperative mood** ("Add feature" not "Added feature")
5. **Reference issues** when applicable (#123)
6. **Update CHANGELOG.md** with the same version entry

### Before Committing

1. Update version number in script header
2. Add entry to CHANGELOG.md following versioning rules in `VERSIONING.md`
3. Test the changes work as expected
4. Follow the commit message format above

## Questions?

Feel free to open an issue for questions about contributing or the codebase.