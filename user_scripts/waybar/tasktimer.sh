# #!/bin/bash
#
# STATE="$HOME/.cache/tasktimer/state.json"
#
# # If state file missing, show nothing
# [ ! -f "$STATE" ] && exit
#
# running=$(jq -r '.running' "$STATE")
#
# # If timer not running, hide module
# [ "$running" != "true" ] && exit
#
# task=$(jq -r '.task' "$STATE")
# start=$(jq -r '.start_time' "$STATE")
#
# now=$(date +%s)
# elapsed=$((now - start))
#
# mins=$((elapsed / 60))
# secs=$((elapsed % 60))
#
#
# printf "⏱ %s %02d:%02d\n" "$task" "$mins" "$secs"
#!/bin/bash

STATE="$HOME/.cache/tasktimer/state.json"

[ ! -f "$STATE" ] && exit

running=$(jq -r '.running' "$STATE")
[ "$running" != "true" ] && exit

task=$(jq -r '.task' "$STATE")
start=$(jq -r '.start_time' "$STATE")
duration=$(jq -r '.duration' "$STATE")

now=$(date +%s)

elapsed=$((now - start))
remaining=$((duration - elapsed))

# prevent negative timer
[ "$remaining" -lt 0 ] && remaining=0

mins=$((remaining / 60))
secs=$((remaining % 60))

printf "⏳ %s %02d:%02d\n" "$task" "$mins" "$secs"
