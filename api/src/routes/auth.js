import { Router } from 'express';
import { registerSignup } from './auth-signup.js';
import { registerToken } from './auth-token.js';
import { registerUser } from './auth-user.js';
import { registerRecovery } from './auth-recovery.js';
import { registerAdmin } from './auth-admin.js';
import { registerAccountDeletion } from './auth-delete.js';
import { registerVkId } from './auth-vkid.js';
import { registerYandexId } from './auth-yandex.js';
import { registerProfileOnboarding } from './auth-profile-onboarding.js';

const router = Router();

registerSignup(router);
registerToken(router);
registerUser(router);
registerRecovery(router);
registerAdmin(router);
registerAccountDeletion(router);
registerVkId(router);
registerYandexId(router);
registerProfileOnboarding(router);

export default router;
