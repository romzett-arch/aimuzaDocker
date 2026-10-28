export type ProviderState={id:string;status:string;paid?:boolean;payment_id?:string;amount:{value:string;currency:string};[key:string]:unknown};
export function verifiedRubles(value: unknown): number {
  if(typeof value!=='string'||!/^[0-9]+\.00$/.test(value)) throw new Error('Unsupported amount precision');
  const amount=Number(value);
  if(!Number.isSafeInteger(amount)||amount<=0||amount>2147483647) throw new Error('Invalid amount');
  return amount;
}
export function assertProviderState(event: string,id: string,data: unknown): asserts data is ProviderState {
  const state=data as ProviderState|undefined;
  const expected:Record<string,string>={'payment.succeeded':'succeeded','payment.canceled':'canceled','payment.waiting_for_capture':'waiting_for_capture','refund.succeeded':'succeeded'};
  if(!state||state.id!==id||!expected[event]||state.status!==expected[event]||state.amount?.currency!=='RUB'||(event==='payment.succeeded'&&state.paid!==true)||(event==='refund.succeeded'&&(!state.payment_id||!/^[a-zA-Z0-9-]{1,80}$/.test(state.payment_id)))) throw new Error('Provider state mismatch');
  verifiedRubles(state.amount.value);
}
