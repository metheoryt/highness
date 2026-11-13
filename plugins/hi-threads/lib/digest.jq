# digest.jq — one Claude Code transcript chunk (JSONL, read with -c) to the lines a reader needs:
# the person's prompts, Claude's prose, each tool call in one short line, tool results cut short.
# Subagent (sidechain) entries, attachments and the harness's injected blocks are dropped.
def clip($n): if length > $n then .[:$n] + " …" else . end;
def strip:
  reduce ("system-reminder", "task-notification", "local-command-stdout", "local-command-stderr",
          "local-command-caveat", "command-message", "command-args", "user-prompt-submit-hook") as $t
    (.; gsub("(?s)<" + $t + "\\b[^>]*>.*?(</" + $t + ">|\\z)"; ""))
  | gsub("</?command-name>"; "")
  | gsub("^\\s+|\\s+$"; "");
def rtext:
  (if (.content | type) == "string" then .content
   elif (.content | type) == "array" then [.content[] | select(.type? == "text") | .text] | join("\n")
   else "" end)
  | split("\n") | .[:6] | join("\n") | clip(400);
def args:
  (.input // {}) as $i
  | if .name == "Bash" then (($i.command // "") | split("\n")[0] | clip(200))
    elif (.name | test("^(Read|Edit|Write|MultiEdit|NotebookEdit)$")) then ($i.file_path // "")
    elif .name == "Skill" then (($i.skill // "") + " " + (($i.args // "") | clip(200)))
    elif .name == "Agent" or .name == "Task" then ($i.description // "")
    else ($i | tojson | clip(160)) end;
def textof: if type == "string" then . else [.[]? | select(.type? == "text") | .text] | join("\n") end;

select((.isSidechain // false) | not)
| if .type == "user" then
    if .isCompactSummary then "[SUMMARY] " + (.message.content | textof | clip(4000))
    elif .isMeta then empty
    else .message.content as $c
      | if ($c | type) == "string" then ($c | strip) as $t | select($t != "") | "[USER] " + ($t | clip(3000))
        else $c[]?
          | if .type == "text" then (.text | strip) as $t | select($t != "") | "[USER] " + ($t | clip(3000))
            elif .type == "tool_result" then "[RESULT] " + rtext
            else empty end
        end
    end
  elif .type == "assistant" then
    .message.content[]?
    | if .type == "text" then (.text | gsub("^\\s+|\\s+$"; "")) as $t | select($t != "") | "[CLAUDE] " + ($t | clip(3000))
      elif .type == "tool_use" then "[TOOL] " + .name + " " + args
      else empty end
  else empty end
