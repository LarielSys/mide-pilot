# Run-Now Checklist

## On Windows Main
1. Copy task.template.json to tasks/TASK-0001.json
2. Fill objective and allowed_paths for Ubuntu scope
3. Mark status as approved_to_execute

## On Ubuntu Worker
1. Read tasks/TASK-0001.json
2. Execute only approved actions
3. Record commands and outputs
4. Save results/TASK-0001.result.json based on result.template.json

## Back on Windows Main
1. Review results/TASK-0001.result.json
2. Decide approve or reject
3. Save approvals/TASK-0001.approval.json
4. Append summary entry to state/ledger.json

## Stop Conditions
1. Any blocked path touched -> reject and quarantine check
2. 3 consecutive failures -> quarantine worker
3. Missing validation evidence -> reject
