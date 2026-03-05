#!/bin/bash
MERCHANT="NotaFeya"
PASS1="TPPFn1edXp8YagO4U0g8"
AMOUNT="100"
INVID="123456789"
SIG_STRING="${MERCHANT}:${AMOUNT}:${INVID}:${PASS1}"
SIG=$(echo -n "$SIG_STRING" | md5sum | awk '{print $1}')
echo "String: $SIG_STRING"
echo "Signature: $SIG"
echo ""
URL="https://auth.robokassa.ru/Merchant/Index.aspx?MerchantLogin=${MERCHANT}&OutSum=${AMOUNT}&InvId=${INVID}&SignatureValue=${SIG}&IsTest=1&Culture=ru"
echo "URL: $URL"
echo ""
HTTP_CODE=$(curl -s -o /tmp/robo-response.html -w '%{http_code}' "$URL")
echo "HTTP Code: $HTTP_CODE"
echo "Response snippet:"
grep -oP 'class="error[^"]*"[^>]*>[^<]*' /tmp/robo-response.html 2>/dev/null | head -5
grep -i 'error_code\|errorCode\|недоступ' /tmp/robo-response.html 2>/dev/null | head -3
head -c 2000 /tmp/robo-response.html | grep -oP '<title>[^<]+' 2>/dev/null
