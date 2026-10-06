/** @type {import('tailwindcss').Config} */
export default {
  content: ["./index.html", "./src/**/*.{ts,tsx}"],
  theme: {
    extend: {
      colors: {
        maroon: { 900: "#8B1E1E", 700: "#A82B2B" },
        navy: { 900: "#1B2A4A" },
        cream: { 50: "#FAF8F5" },
        ink: { 900: "#232323" },
        sand: { 200: "#E8E2D8" },
        status: { ok: "#2E7D4F", warn: "#C77A1F", escalate: "#8B1E1E" },
      },
      fontFamily: {
        sans: ["Inter", "ui-sans-serif", "system-ui", "sans-serif"],
        display: ["Fraunces", "Georgia", "serif"],
      },
    },
  },
  plugins: [],
};