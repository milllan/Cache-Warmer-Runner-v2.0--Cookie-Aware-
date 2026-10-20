# Cache Warmer Project

## Project Overview

This project is a shell-script based cache warming system designed to pre-load web pages into cache (e.g., CDN, server-side cache) by crawling sitemaps. It supports concurrent execution, mobile/desktop user agent simulation, and specific origin IP targeting to bypass proxies (like Cloudflare) if needed.

## Key Components

*   **`master-warmer.sh`**: The orchestrator script. It parses the `sites.conf` file and dispatches `cache-warmer.sh` jobs up to a configured concurrency limit (default: 9).
*   **`cache-warmer.sh`**: The worker script. It processes a single site:
    *   Downloads and parses the sitemap (and nested sitemaps).
    *   Filters URLs based on `warmer_exclusions.txt`.
    *   Visits each URL using `curl` with both Desktop and Mobile User Agents.
    *   Records performance metrics (time to first byte/load time).
*   **`sites.conf`**: Configuration file listing sites to warm.
*   **`warmer_exclusions.txt`**: A list of string patterns (grep-compatible) to exclude specific URLs from being warmed.

## Configuration

### `sites.conf`

The configuration file controls which sites are processed. Each line represents a task.

**Format:**
```text
domain.com sitemap_path [origin_ip]
```

*   **`domain.com`**: The hostname of the site.
*   **`sitemap_path`**: Relative path to the sitemap (e.g., `sitemap.xml` or `sitemap_index.xml`). The script constructs the URL as `https://domain.com/sitemap_path`.
*   **`[origin_ip]`** (Optional): If provided, `curl` will resolve the domain to this specific IP address. Useful for warming origin servers directly behind a CDN.

**Example:**
```text
# Standard usage
example.com sitemap.xml

# With specific Origin IP
backend.example.com sitemap_index.xml 192.168.1.10
```

### `warmer_exclusions.txt`
Add patterns here to skip specific URLs. This file is passed to `grep -vFf` to filter the URL list.

## Usage

### Running the Warmer

Execute the master script to start the process:

```bash
./master-warmer.sh [verbose]
```

*   **Standard Run:** `./master-warmer.sh` - Runs in background/quiet mode suitable for cron jobs.
*   **Verbose Run:** `./master-warmer.sh verbose` - Outputs detailed logs to stdout.

### System Dependencies

The scripts require the following Linux packages:
*   `curl`: For fetching URLs.
*   `bc`: For floating-point arithmetic (calculating sleep times and stats).
*   `xmlstarlet`: For robust XML sitemap parsing.

## Logging & Output

*   **`logs/master.log`**: High-level log of the orchestrator (start/stop times, job dispatching).
*   **`logs/<domain>.log`**: Detailed logs for each specific site run (e.g., `logs/example.com.log`).
*   **`logs/stats.csv`**: A CSV file compiling performance statistics for each run.
    *   Columns: `timestamp, domain, total_unique_urls, urls_warmed, desktop_min, desktop_max, desktop_avg, mobile_min, mobile_max, mobile_avg`

## Architecture Details

*   **Concurrency:** The `master-warmer.sh` script limits concurrent jobs using `MAX_JOBS` (default 9) to prevent overloading the local machine.
*   **Locking:**
    *   Uses `flock` to ensure only one instance of the warmer runs per site at a time.
    *   Lock files are stored in `run/`.
*   **Politeness:**
    *   The `cache-warmer.sh` calculates a "sleep" time between requests based on the response time of the previous request (slower response = longer pause) to avoid DoS-ing the target server.
