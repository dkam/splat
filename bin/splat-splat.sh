while IFS= read -r line; do
  echo "$line" | curl -s -X POST http://100.86.148.37:3031/mcp \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer shi5Ieh8voxiex7ain1Deech5yoeh1oh" \
    -d @-
done
