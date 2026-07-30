// Two first-class themes, per the constitution. The toggle writes a
// preference; absent one, the OS decides.
(() => {
  const root = document.documentElement;

  const label = () => (root.classList.contains("dark") ? "Light" : "Dark");

  const sync = () => {
    document.querySelectorAll("[data-theme-toggle]").forEach((el) => {
      el.textContent = label();
    });
  };

  document.querySelectorAll("[data-theme-toggle]").forEach((el) => {
    el.addEventListener("click", () => {
      const dark = root.classList.toggle("dark");
      localStorage.setItem("superx:theme", dark ? "dark" : "light");
      sync();
    });
  });

  sync();
})();
