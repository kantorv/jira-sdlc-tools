Here's an updated version with the workflow you described.

# Installing and Updating GitHub CLI (`gh`) on Ubuntu

The Ubuntu package repositories often contain an outdated version of GitHub CLI. To ensure compatibility with the latest GitHub APIs and features, install `gh` from GitHub's official APT repository.

## Check Whether `gh` Is Installed

First, check whether GitHub CLI is already installed:

```bash
command -v gh >/dev/null && gh --version || echo "gh is not installed"
```

If `gh` is installed, note the version:

```bash
gh --version
```

Then compare it with the latest release:

* [GitHub CLI Releases](https://github.com/cli/cli/releases?utm_source=chatgpt.com)

If your installed version is reasonably recent and meets your team's requirements, no action is needed.

If the installed version is significantly older than the latest release (for example, an Ubuntu-packaged version such as `2.4.0+dfsg1`), update it by installing the official GitHub CLI package as described below. Older versions may fail due to GitHub API changes. ([GitHub][1])

## Remove the Ubuntu Package (if installed)

```bash
sudo apt remove -y gh
```

## Add the Official GitHub CLI Repository

```bash
# Install wget if needed
type -p wget >/dev/null || sudo apt install -y wget

# Create the keyring directory
sudo mkdir -p -m 755 /etc/apt/keyrings

# Download and install the repository signing key
wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null

sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg

# Add the GitHub CLI repository
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
  | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
```

## Install or Update GitHub CLI

```bash
sudo apt update
sudo apt install -y gh
```

Verify the installed version:

```bash
gh --version
```

## Keep GitHub CLI Up to Date

Once the official GitHub CLI repository has been configured, updating `gh` is straightforward:

```bash
sudo apt update
sudo apt install --only-upgrade gh
```

Or update it together with the rest of the system packages:

```bash
sudo apt update
sudo apt upgrade
```

## Why Use the Official Repository?

The `gh` package provided by Ubuntu distributions may lag several years behind the latest release. Older versions can become incompatible with GitHub due to API changes (for example, the deprecation of Projects (classic) GraphQL APIs). Installing from the official GitHub repository ensures you receive regular updates, bug fixes, new features, and compatibility with GitHub's current APIs. ([GitHub][1])

[1]: https://github.com/cli/cli "GitHub - cli/cli: GitHub’s official command line tool · GitHub"




# Updating GITHUB repository settings

We need to enable `GitHub Actions` to `Create Pull Requests` in repository settings.
By default, GitHub blocks automated workflows from creating pull requests. If your release or automation workflows are failing with the error `GraphQL: GitHub Actions is not permitted to create or approve pull requests`, follow these steps to grant the necessary repository permissions.

## 🛠️ Step-by-Step Instructions

1. **Navigate to Settings**
Open your repository in GitHub and click the **Settings** (gear icon) tab in the top navigation bar.
2. **Go to Actions Configuration**
In the left sidebar, locate the **Code and automation** section, click on **Actions**, and select **General**.
3. **Update Workflow Permissions**
Scroll down to the **Workflow permissions** section at the bottom of the page.
* Check the box for **"Allow GitHub Actions to create and approve pull requests"**.
* *(Optional)* Ensure the default permission is set to **"Read and write permissions"**.


4. **Save Changes**
Click the **Save** button to apply the updates.

---

## 🛑 Troubleshooting: Greyed Out Option?

If the checkbox is disabled or displays a message stating that the policy is enforced by your organization, a GitHub Organization Owner must enable it globally:

1. Go to the **Organization Settings**.
2. Navigate to **Actions** $\rightarrow$ **General**.
3. Under **Workflow permissions**, select **"Allow GitHub Actions to create and approve pull requests"** and save.