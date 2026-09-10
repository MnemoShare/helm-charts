def reject($message): error("migration-result/v1: " + $message);

if type != "array" then
  reject("expected a slurped jq stream-event array")
elif any(.[]; (.[0] | length) != 1) then
  reject("expected exactly one flat top-level object")
else
  [ .[] | select(length == 2) | {key: .[0][0], value: .[1]} ] as $fields
  | if ($fields | length) != 2 or ($fields | map(.key) | sort) != ["decision", "planDigest"] then
      reject("expected exactly one decision and one planDigest")
    else
      ($fields | from_entries) as $result
      | if ($result.decision | type) != "string" or
           (($result.decision == "ordinary" or $result.decision == "maintenance") | not) then
          reject("decision must be ordinary or maintenance")
        elif ($result.planDigest | type) != "string" or
             (($result.planDigest | test("^[0-9a-f]{64}$")) | not) then
          reject("planDigest must be 64 lowercase hexadecimal characters")
        else
          $result
        end
    end
end
