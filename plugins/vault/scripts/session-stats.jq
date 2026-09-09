def real_prompts: [ .[] | select(.type=="user" and (.toolUseResult|not)) ];
def assistants:   [ .[] | select(.type=="assistant") ];
def tool_uses:    [ .[] | select(.type=="assistant")
                        | .message.content[]? | select(.type=="tool_use") ];
def stamps:       [ .[] | .timestamp? // empty ] | sort;

(stamps | first) as $start |
(stamps | last)  as $end   |
(tool_uses) as $tu |

([ $tu[] | select(.name=="Edit" or .name=="Write" or .name=="NotebookEdit")
         | .input.file_path? // empty ] | unique) as $written |
([ $tu[] | select(.name=="Read") | .input.file_path? // empty ] | unique) as $read |

{
  ok: true,
  session_id:   ([ .[] | .sessionId? // empty ] | last),
  cwd:          ([ .[] | .cwd? // empty ] | last),
  git_branch:   ([ .[] | select(.gitBranch? != null and .gitBranch? != "HEAD") | .gitBranch ] | last),
  model:        ([ .[] | select(.type=="assistant") | .message.model? // empty ] | unique | join(",")),
  started_at:   $start,
  ended_at:     $end,
  # fromdateiso8601 rejects fractional seconds; transcripts always carry them.
  duration_min: (if $start and $end
                 then ((($end   | sub("\\.[0-9]+Z$";"Z") | fromdateiso8601) -
                        ($start | sub("\\.[0-9]+Z$";"Z") | fromdateiso8601)) / 60 | floor)
                 else null end),

  prompts:      (real_prompts | length),
  turns:        (assistants   | length),
  tool_calls:   ($tu | length),
  tools:        ([ $tu[] | .name ] | unique),
  tool_counts:  ([ $tu[] | .name ] | group_by(.) | map({key: .[0], value: length}) | from_entries),

  files_written: $written,
  files_read:    $read,
  files_touched: ($written | length),

  errors: ([ .[] | select(.type=="user")
                 | .message.content[]? | select(.type=="tool_result" and .is_error==true) ] | length),

  tokens: {
    input:      ([ .[] | select(.type=="assistant") | .message.usage.input_tokens?  // 0 ] | add // 0),
    output:     ([ .[] | select(.type=="assistant") | .message.usage.output_tokens? // 0 ] | add // 0),
    cache_read: ([ .[] | select(.type=="assistant") | .message.usage.cache_read_input_tokens? // 0 ] | add // 0)
  },

  first_prompt: (real_prompts | first | .message.content
                 | if type=="string" then . else ([ .[]? | select(.type=="text") | .text ] | join(" ")) end
                 | tostring | .[0:400])
}
