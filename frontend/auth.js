import { createClient } from "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm";

const supabaseConfig = window.CampusConnectApiConfig || {};
const projectUrl = String(supabaseConfig.supabaseProjectUrl || "").trim();
const publishableKey = String(supabaseConfig.supabasePublishableKey || "").trim();

function isPlaceholder(value) {
  return !value ||
    value.includes("YOUR_SUPABASE") ||
    value.includes("PLACEHOLDER");
}

function isUnsafeKey(key) {
  return key.toLowerCase().includes("service_role") ||
    key.toLowerCase().startsWith("sb_secret");
}

function getConfigurationError() {
  if (isPlaceholder(projectUrl) || isPlaceholder(publishableKey)) {
    return "Supabase configuration is incomplete. Paste the Project URL and publishable key in frontend/api-config.js.";
  }

  if (!/^https?:\/\//i.test(projectUrl)) {
    return "The Supabase Project URL must be a valid HTTP or HTTPS URL.";
  }

  if (isUnsafeKey(publishableKey)) {
    return "A service-role or secret key was detected. Use only the Supabase publishable/anon key.";
  }

  return "";
}

const configurationError = getConfigurationError();
let supabase = null;

if (!configurationError) {
  supabase = createClient(projectUrl, publishableKey, {
    auth: {
      persistSession: true,
      autoRefreshToken: true,
      detectSessionInUrl: true
    }
  });
}

function friendlyAuthError(error) {
  const message = String(error?.message || "").toLowerCase();

  if (message.includes("invalid login credentials")) {
    return "The email or password is incorrect.";
  }
  if (message.includes("email not confirmed")) {
    return "Please confirm your email address before logging in.";
  }
  if (message.includes("user already registered")) {
    return "An account with this email already exists.";
  }
  if (message.includes("password")) {
    return "Password must meet the Supabase project requirements.";
  }
  if (message.includes("network") || message.includes("fetch")) {
    return "Could not reach Supabase. Check your connection and try again.";
  }
  if (message.includes("invalid api key")) {
    return "The Supabase publishable key is invalid.";
  }

  return error?.message || "Authentication could not be completed.";
}

async function signUp(email, password) {
  if (configurationError) throw new Error(configurationError);
  const emailRedirectTo = getProductionRedirect("exploreevnts.html");
  const { data, error } = await supabase.auth.signUp({
    email: email.trim(),
    password,
    options: { emailRedirectTo }
  });

  if (error) throw error;
  return data;
}

async function signUpWithName(fullName, email, password) {
  if (configurationError) throw new Error(configurationError);

  const { data, error } = await supabase.auth.signUp({
    email: email.trim(),
    password,
    options: {
      emailRedirectTo: getProductionRedirect("exploreevnts.html"),
      data: { full_name: fullName.trim() }
    }
  });

  if (error) throw error;
  return data;
}

async function signIn(email, password) {
  if (configurationError) throw new Error(configurationError);

  const { data, error } = await supabase.auth.signInWithPassword({
    email: email.trim(),
    password
  });

  if (error) throw error;
  return data;
}

async function signOut() {
  if (!supabase) return;
  const { error } = await supabase.auth.signOut();
  if (error) throw error;
}

async function getSession() {
  if (!supabase) return null;
  const { data, error } = await supabase.auth.getSession();
  if (error) throw error;
  return data.session;
}

async function getUser() {
  if (!supabase) return null;
  const { data, error } = await supabase.auth.getUser();
  if (error) throw error;
  return data.user;
}

async function getAccessToken() {
  const session = await getSession();
  return session?.access_token || null;
}

function getProductionRedirect(page) {
  if (
    window.location.hostname === "localhost" ||
    window.location.hostname === "127.0.0.1"
  ) {
    return new URL(page, window.location.href).href;
  }

  return `https://campusconnect-frontend-alpha-sand.vercel.app/${page}`;
}

async function sendPasswordReset(email) {
  if (configurationError) throw new Error(configurationError);

  const { error } = await supabase.auth.resetPasswordForEmail(email.trim(), {
    redirectTo: getProductionRedirect("reset-password.html")
  });

  if (error) throw error;
}

async function updatePassword(newPassword) {
  if (configurationError) throw new Error(configurationError);

  const { error } = await supabase.auth.updateUser({
    password: newPassword
  });

  if (error) throw error;
}

function getInitials(user) {
  const value = user?.email || "Student";
  return value.slice(0, 2).toUpperCase();
}

async function updateAuthControls() {
  const containers = document.querySelectorAll("[data-auth-controls]");
  if (!containers.length) return;

  let user = null;
  if (!configurationError) {
    try {
      user = await getUser();
    } catch {
      user = null;
    }
  }

  containers.forEach((container) => {
    if (configurationError) {
      container.innerHTML = `
        <a href="login.html" class="px-3 py-2 rounded-full text-sm font-semibold text-brand-700 hover:bg-brand-50 transition-colors" title="${friendlyAuthError(new Error(configurationError))}">Login</a>
        <a href="signup.html" class="px-3 py-2 rounded-full text-sm font-semibold text-white bg-brand-600 hover:bg-brand-700 transition-colors">Sign Up</a>
      `;
      return;
    }

    if (user) {
      container.innerHTML = `
        <span class="hidden sm:inline text-sm font-semibold text-slate-700">${escapeHtml(getUserLabel(user))}</span>
        <button type="button" data-auth-logout class="px-3 py-2 rounded-full text-sm font-semibold text-brand-700 border border-brand-100 bg-white hover:bg-brand-50 transition-colors">Logout</button>
      `;

      container.querySelector("[data-auth-logout]")?.addEventListener("click", async () => {
        try {
          await signOut();
          window.location.href = "exploreevnts.html";
        } catch (error) {
          window.alert(friendlyAuthError(error));
        }
      });
    } else {
      container.innerHTML = `
        <a href="login.html" class="px-3 py-2 rounded-full text-sm font-semibold text-brand-700 hover:bg-brand-50 transition-colors">Login</a>
        <a href="signup.html" class="px-3 py-2 rounded-full text-sm font-semibold text-white bg-brand-600 hover:bg-brand-700 transition-colors">Sign Up</a>
      `;
    }
  });
}

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function getUserLabel(user) {
  return (
    user?.user_metadata?.full_name ||
    user?.user_metadata?.name ||
    user?.email ||
    "Student"
  );
}

window.CampusConnectAuth = {
  client: supabase,
  configurationError,
  signUp,
  signUpWithName,
  signIn,
  signOut,
  getSession,
  getUser,
  getAccessToken,
  sendPasswordReset,
  updatePassword,
  friendlyAuthError,
  updateAuthControls
};

document.addEventListener("DOMContentLoaded", updateAuthControls);

if (supabase) {
  supabase.auth.onAuthStateChange(() => {
    updateAuthControls();
  });
}
