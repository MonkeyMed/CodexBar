# Native notification interaction record

All versions and accounts in this fixture are synthetic. The fixture has its own application identifier and preference domain. No live provider requests or Homebrew installation were performed.

## Observed actions

1. Built the full application from production commit `c16e1a6f7f6f85be9e6f9b26bdd2438e3d57e8f9`, with the documentation-only entry point and synthetic updater dependencies described in the build receipt. The bundle passed strict ad-hoc signature verification.
2. Launch 1 observed the system's denied notification authorization. The production notifier did not save a successfully submitted version.
3. Enabled notifications for the fixture application through the macOS Notifications settings page. The real system center subsequently returned the `99.0.1` notification as delivered, and the production notifier saved that version.
4. Rebuilt the fixture to add its control window and exclude ordinary provider/status-item startup. Production notification and settings-route sources were unchanged. Launch 2 loaded the saved submitted version, ran its automatic startup check, and did not submit `99.0.1` again.
5. Clicked **Check next synthetic version** twice in the fixture control window. Those controls called the production automatic-check path. The real system center returned the successive silent `99.0.2` and `99.0.3` requests as delivered.

6. The user's initial click report could not be attributed to a notification card; the user was unsure which surface they had clicked, and no About transition followed. That report is excluded from click proof. A later automatic check still ran and did not duplicate `99.0.3`; another synthetic version produced the delivered `99.0.4` notification.
7. Used **Open update settings** to open the production About pane in launch 2. This manual control action is explicitly recorded in [ui-interactions.json](ui-interactions.json) and excluded from notification-click proof. Turned off the real **Check for updates automatically** switch. The application observed both the saved preference and controller flag become false, and the delivered `99.0.4` notification was removed.
8. Quit through Command-Q and launched the same bundle again. Launch 3 loaded the saved false preference, performed zero startup fetches, and contained no delivered notifications. **Observe automatic check** also recorded zero fetches before and after. Manually reopened About; its actual switch remained off, as shown by the [screenshot](automatic-check-disabled-after-restart.jpg) and [accessibility capture](automatic-check-disabled-after-restart.txt).
9. Rebuilt and strictly verified the signed fixture from maintainer-synchronized commit `54ada0fe3`. All six production notification/settings source hashes matched the earlier receipt. Launch 4 again loaded the false preference and performed zero startup fetches. Manually enabled the production About switch, closed settings, and produced `99.0.5` through the automatic-check path.
10. Confirmed that the real notification center reported `99.0.5` as delivered and silent, then quit the fixture with Command-Q. The exact fixture executable was absent from the process inventory. This prepares a true cold-launch notification click without manually starting the app.

No real notification-card click is established by these actions. The captured About transitions are manual settings opens, not click-to-About evidence.

## Remaining native interactions

The computer-use surface exposed notification widgets but not the notification cards; an earlier attempt was also blocked by the locked Mac. The available interface cannot autonomously click a native notification card. The pending human-assisted action is to click the fixture's `99.0.5` notification while the fixture is quit.

After that click:

1. Confirm the fixture launches through the real notification, then its production About window opens after delayed settings configuration. Correlate the window transition with the native event receipt and capture UI evidence.
2. Produce a newer synthetic notification while the fixture runs, close settings, and click that real notification card. Confirm the production About window opens.
3. Restart without changing the available version and confirm no additional notification is submitted.

Refresh the public event and verification receipts after those interactions. The maintainer has marked the PR ready for review; this does not establish the remaining native click evidence or approval for merge.
