set -euo pipefail

presidio-analyzer &
server=$!
trap 'kill "$server"' EXIT

origin="http://127.0.0.1:$PORT"
for _ in $(seq 1 600); do
  if curl -fsS "$origin/health" > health.txt 2> /dev/null; then
    break
  fi
  if ! kill -0 "$server" 2> /dev/null; then
    echo "presidio-analyzer exited before answering /health"
    exit 1
  fi
  sleep 0.5
done
grep -q "Presidio Analyzer service is up" health.txt

curl -fsS "$origin/recognizers?language=de" > recognizers.json
jq -e 'index("EmailRecognizer") and index("IbanRecognizer") and index("PhoneRecognizer")' recognizers.json
jq -e 'index("InVoterRecognizer") | not' recognizers.json

curl -fsS "$origin/analyze" \
  -H "Content-Type: application/json" \
  -d '{"language": "de", "text": "Max Mustermann aus Berlin bittet, an max.mustermann@example.com zu schreiben oder an DE89 3704 0044 0532 0130 00 zu überweisen."}' \
  > analyze.json
jq -e '[.[].entity_type] | index("PERSON") and index("LOCATION") and index("EMAIL_ADDRESS") and index("IBAN_CODE")' analyze.json
