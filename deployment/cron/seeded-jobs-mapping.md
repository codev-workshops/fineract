# Quartz -> EventBridge Scheduler cron mapping

Tenant timezone applied to every schedule: `Asia/Kolkata` (EventBridge Scheduler `ScheduleExpressionTimezone`).

| job | Quartz cron | EventBridge schedule_expression | 1:1 | notes |
| --- | --- | --- | --- | --- |
| Update loan Summary | `0 0 22 1/1 * ? *` | `cron(0 22 * * ? *)` | yes |  |
| Update Loan Arrears Ageing | `0 1 0 1/1 * ? *` | `cron(1 0 * * ? *)` | yes |  |
| Update Loan Paid In Advance | `0 5 0 1/1 * ? *` | `cron(5 0 * * ? *)` | yes |  |
| Apply Annual Fee For Savings | `0 20 22 1/1 * ? *` | `cron(20 22 * * ? *)` | yes |  |
| Apply Holidays To Loans | `0 0 12 * * ?` | `cron(0 12 * * ? *)` | yes |  |
| Post Interest For Savings | `0 0 0 1/1 * ? *` | `cron(0 0 * * ? *)` | yes |  |
| Transfer Fee For Loans From Savings | `0 1 0 1/1 * ? *` | `cron(1 0 * * ? *)` | yes |  |
| Pay Due Savings Charges | `0 0 12 * * ?` | `cron(0 12 * * ? *)` | yes |  |
| Update Accounting Running Balances | `0 1 0 1/1 * ? *` | `cron(1 0 * * ? *)` | yes |  |
| Execute Standing Instruction | `0 0 0 1/1 * ? *` | `cron(0 0 * * ? *)` | yes |  |
| Add Accrual Transactions | `0 1 0 1/1 * ? *` | `cron(1 0 * * ? *)` | yes |  |
| Apply penalty to overdue loans | `0 0 0 1/1 * ? *` | `cron(0 0 * * ? *)` | yes |  |
| Update Non Performing Assets | `0 0 0 1/1 * ? *` | `cron(0 0 * * ? *)` | yes |  |
| Transfer Interest To Savings | `0 2 0 1/1 * ? *` | `cron(2 0 * * ? *)` | yes |  |
| Update Deposit Accounts Maturity details | `0 0 0 1/1 * ? *` | `cron(0 0 * * ? *)` | yes |  |
| Add Periodic Accrual Transactions | `0 2 0 1/1 * ? *` | `cron(2 0 * * ? *)` | yes |  |
| Recalculate Interest For Loans | `0 1 0 1/1 * ? *` | `cron(1 0 * * ? *)` | yes |  |
| Generate Mandatory Savings Schedule | `0 5 0 1/1 * ? *` | `cron(5 0 * * ? *)` | yes |  |
| Generate Loan Loss Provisioning | `0 0 0 1/1 * ? *` | `cron(0 0 * * ? *)` | yes |  |
| Post Dividends For Shares | `0 0 0 1/1 * ? *` | `cron(0 0 * * ? *)` | yes |  |
| Update Savings Dormant Accounts | `0 0 0 1/1 * ? *` | `cron(0 0 * * ? *)` | yes |  |
| Add Accrual Transactions For Loans With Income Posted As Transactions | `0 1 0 1/1 * ? *` | `cron(1 0 * * ? *)` | yes |  |
| Execute Report Mailing Jobs | `0 0/15 * * * ?` | `cron(0/15 * * * ? *)` | yes |  |
| Update SMS Outbound with Campaign Message | `0 0 5 1/1 * ? *` | `cron(0 5 * * ? *)` | yes |  |
| Send Messages to SMS Gateway | `0 0 5 1/1 * ? *` | `cron(0 5 * * ? *)` | yes |  |
| Get Delivery Reports from SMS Gateway | `0 0 5 1/1 * ? *` | `cron(0 5 * * ? *)` | yes |  |
| Execute Email | `0 0/10 * * * ?` | `cron(0/10 * * * ? *)` | yes |  |
| Update Email Outbound with campaign message | `0 0/15 * * * ?` | `cron(0/15 * * * ? *)` | yes |  |
| Generate AdhocClient Schedule | `0 0 12 1/1 * ? *` | `cron(0 12 * * ? *)` | yes |  |
| Update Trial Balance Details | `0 1 0 1/1 * ? *` | `cron(1 0 * * ? *)` | yes |  |
| Execute All Dirty Jobs | `0 1 0 1/1 * ? *` | `cron(1 0 * * ? *)` | yes |  |

