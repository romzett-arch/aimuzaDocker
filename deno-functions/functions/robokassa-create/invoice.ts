import { createHmac } from "node:crypto";

export interface RobokassaInvoicePayload {
  MerchantLogin: string;
  InvId: number;
  InvoiceType: "OneTime";
  Culture: "ru";
  OutSum: number;
  Description: string;
  Sno: "usn_income";
  InvoiceItems: Array<{
    Name: string;
    Quantity: number;
    Cost: number;
    Tax: "none";
    PaymentMethod: "full_payment";
    PaymentObject: "service";
  }>;
  Aliases: ["BankCard"];
  SuccessUrl2Data: { Url: string; Method: "GET" };
  FailUrl2Data: { Url: string; Method: "GET" };
  AdditionalParameters: Record<string, string>;
}

function toBase64Url(value: unknown): string {
  const bytes = new TextEncoder().encode(JSON.stringify(value));
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary)
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "");
}

export function createInvoiceJwt(
  payload: RobokassaInvoicePayload,
  merchantLogin: string,
  password1: string,
): string {
  const header = { typ: "JWT", alg: "MD5" };
  const signingInput = `${toBase64Url(header)}.${toBase64Url(payload)}`;
  const signature = createHmac("md5", `${merchantLogin}:${password1}`)
    .update(signingInput)
    .digest("base64url");
  return `${signingInput}.${signature}`;
}

export function buildBankCardInvoicePayload(input: {
  merchantLogin: string;
  invId: string;
  amount: number;
  description: string;
  email: string;
  successUrl: string;
  failUrl: string;
  isTest: boolean;
}): RobokassaInvoicePayload {
  const additionalParameters: Record<string, string> = {
    Email: input.email,
    IncCurrLabel: "BankCard",
    PaymentMethods: JSON.stringify(["BankCard"]),
  };
  if (input.isTest) additionalParameters.IsTest = "1";

  return {
    MerchantLogin: input.merchantLogin,
    InvId: Number(input.invId),
    InvoiceType: "OneTime",
    Culture: "ru",
    OutSum: input.amount,
    Description: input.description.slice(0, 100),
    Sno: "usn_income",
    InvoiceItems: [
      {
        Name: input.description.slice(0, 128),
        Quantity: 1,
        Cost: input.amount,
        Tax: "none",
        PaymentMethod: "full_payment",
        PaymentObject: "service",
      },
    ],
    Aliases: ["BankCard"],
    SuccessUrl2Data: { Url: input.successUrl, Method: "GET" },
    FailUrl2Data: { Url: input.failUrl, Method: "GET" },
    AdditionalParameters: additionalParameters,
  };
}
