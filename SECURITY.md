# Security

CoordinatedCalendar runs entirely on your Mac and sends nothing about your calendars anywhere (its only network request asks GitHub for the latest release number), but it reads every calendar you grant it and writes copies across accounts. Problems that could leak event details between accounts, delete events it did not create, or expose calendar data matter to us.

## Reporting a problem

Please report security or privacy problems privately using GitHub's **Report a vulnerability** button on the repository's **Security** tab, not in a public issue. Include the macOS version, what you expected, what happened, and steps to reproduce with sample calendars. Please don't send real calendar data.

You can expect an acknowledgement within a week. Fixes are released as soon as they are verified, with credit if you'd like it.

## Supported versions

Only the latest release on `main` receives fixes.
