/** Full Robokassa checkout without filtering the merchant's payment methods. */
export function buildHostedCheckoutUrl(input: {
  merchantLogin: string;
  outSum: string;
  invId: string;
  description: string;
  encodedReceipt: string;
  signature: string;
  isTest: boolean;
  email?: string;
}): string {
  const url = new URL('https://auth.robokassa.ru/Merchant/Index.aspx');
  url.searchParams.set('MerchantLogin', input.merchantLogin);
  url.searchParams.set('OutSum', input.outSum);
  url.searchParams.set('InvId', input.invId);
  url.searchParams.set('Description', input.description.slice(0, 100));
  url.searchParams.set('Culture', 'ru');
  url.searchParams.set('Encoding', 'utf-8');
  // Receipt is URL-encoded before signing, then encoded for URL transport.
  url.searchParams.set('Receipt', input.encodedReceipt);
  url.searchParams.set('SignatureValue', input.signature);
  if (input.isTest) url.searchParams.set('IsTest', '1');
  if (input.email) url.searchParams.set('Email', input.email);
  return url.toString();
}
