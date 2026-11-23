
window.CampusConnectApiConfig = {
  // Supabase Project URL
  supabaseProjectUrl: "https://ygfjcxdxikyqswudocnl.supabase.co",

  // Supabase publishable key (safe for frontend)
  supabasePublishableKey: "sb_publishable_4TuJ3Tz9-l58NwbX16IwmA_Rkun2xkH",

  // FastAPI backend URL
  baseUrl:
    window.location.hostname === "localhost" ||
    window.location.hostname === "127.0.0.1"
      ? "http://127.0.0.1:8000/api"
      : "https://campusconnect-secb.onrender.com/api"
};
