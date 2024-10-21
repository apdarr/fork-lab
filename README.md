# Demo of PR rebuild based on forks

After a migration using GitHub's GEI, the source PRs created from forks are left with detached commits. This script automates recrated these migrated PRs in organizations that rely on a fork-based workflow. It also copies over review comments and soon, general comments.

## Installation

1. **Clone the Repository**
   ```bash
   git clone https://github.com/yourusername/pr-rebuilder-demo.git
   cd pr-rebuilder-demo

## Requirements

Before getting started, ensure you have the following installed on your machine:

- **Ruby** (installation instructions)
- **Bundler** (After you install Ruby: `gem install bundler`)

### .env file

In the same directory as the script, create a file named `.env` and add the following content:

```
GHEC_TOKEN= # Your GitHub enterprise cloud PAT
TARGET_ORG= # the org in the target GHEC where your forks will live
```

## What It Does
This script automates the process of rebuilding pull requests based on forks. Here's a high-level overview of its functionality:

- Authentication: Connects to GitHub or GitHub Enterprise using the provided access token.
- Fetching PRs: Retrieves all PRs from the specified repository that are based on forks.
- Rebuilding PRs:
  - Creates forks in the target organization.
  - Reconstructs commits and branches as needed.
  - Reopens or creates new PRs based on the original ones.
  - Handling Comments: Copies over review comments and (soon) general comments to the new PRs to maintain context.

Future Improvements
While this project serves as a solid foundation, there are several areas slated for future enhancements:

- Copying of general comments from the source PR, not attached to a review. 
- Handling resolution status of review comments.
- Adding PR reviewers to target PR.
- Enhanced Error Handling: Improve robustness by handling more edge cases and potential failures.
User Interface: Develop a CLI with more intuitive commands and options.
- Integration Tests: Add comprehensive tests to ensure reliability.
- Performance Optimizations: Optimize for handling large repositories with numerous PRs.
- Documentation: Expand documentation for better clarity and ease of use.

## Usage
Run the script with the required argument: 

```bash
ruby script.rb -r my-org/my-repo
```


## Disclaimer
This project is a work in progress and is not yet intended for production use. It's designed to demonstrate the concept of rebuilding PRs based on forks post-migration.