import { CalendarSettingsPanel } from "../calendar/CalendarSettingsPanel";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { ReactNode } from "react";
import { showToast, ToastHost } from "../../app/toast";
import {
  ADD_COURSE_SHORTCUT_EVENT,
  IMPORT_MATERIALS_SHORTCUT_EVENT,
} from "../../app/shortcuts";
import { BandalMark } from "../../components/BandalMark";
import { useLocale, useT } from "../../i18n";
import { invoke, onPush } from "../../lib/ipc";
import { useCoursesStore } from "../../stores/coursesStore";
import { useUiStore } from "../../stores/uiStore";
import { usePluginsStore } from "../../stores/pluginsStore";
import {
  AGENT_PROVIDERS,
  type AgentAvailability,
  type AgentProvider,
} from "../../../../shared/types/agent-events";
import { acquireAgentConnection, refreshAgentConnection, useAgentConnectionStore } from "../chat/agentConnectionStore";
import type { Course } from "../../../../shared/types/course";
import {
  isSameAppearance,
  pickAppearance,
} from "../../../../shared/appearance";
import type { AppearanceSettings } from "../../../../shared/appearance";
import {
  isSettingsCategoryId,
  normalizeSettingsCategoryId,
  SETTINGS_CATEGORIES,
  SETTINGS_GROUPS,
  type SettingsPanelId,
  type SettingsGroupId,
} from "../../../../shared/settingsCategories";
import {
  DEFAULT_SETTINGS,
  type Density,
  type EditorFont,
  type FontScale,
  type Settings,
  type ThemePreference,
} from "../../../../shared/types/settings";
import { AccountPanel } from "./AccountPanel";
import { AdvancedPanel } from "./advanced/AdvancedPanel";
import { AssistantPanel } from "./assistant/AssistantPanel";
import { ExperimentalPanel } from "./advanced/ExperimentalPanel";
import { BrowserSettingsPanel } from "./browser/BrowserSettingsPanel";
import {
  AboutPanel,
  AiPanel,
  AppearancePanel,
  CoursesPanel,
  GeneralPanel,
} from "./SettingsPanels";
import { PluginsCategoryPanel } from "./PluginsCategoryPanel";
import { NotificationsPanel } from "./notifications/NotificationsPanel";
import { PermissionsPanel } from "./permissions/PermissionsPanel";
import { PrivacyPanel } from "./privacy/PrivacyPanel";
import { ShortcutsPanel } from "./shortcuts/ShortcutsPanel";
import { UsagePanel } from "./usage/UsagePanel";
import { Icon } from "./SettingsIcon";
import { searchSettings } from "./settingsSearchIndex";
import { applyTheme } from "./settingsTheme";
import { UniversitySettingsPanel } from "./UniversitySettingsPanel";
import { WidgetSettingsPanel } from "./WidgetSettingsPanel";
import { TabsSettingsPanel } from "./TabsSettingsPanel";
import {
  HELP_FOCUS_TARGET_EVENT,
  milestoneDestination,
} from "../help/HelpHub";
import { MilestonesOverlay } from "../help/MilestonesOverlay";
import { ProgressRing } from "../help/ProgressRing";
import { useMilestones, type MilestoneId } from "../help/milestonesStore";
import { useTourStore } from "../onboarding/tour/tourStore";
import "../help/help.css";
import "./settings-app.css";
import "./settings-panels.css";

interface Category {
  id: SettingsPanelId;
  group: SettingsGroupId;
  label: string;
  description: string;
}

interface SettingsAppProps {
  embedded?: boolean;
  onClose?: () => void;
  /** Category to open on; unknown/null falls back to General. */
  initialCategory?: string | null;
}

type ProviderState<T> = Record<AgentProvider, T>;

export function SettingsApp({
  embedded = false,
  onClose,
  initialCategory = null,
}: SettingsAppProps = {}): JSX.Element {
  const t = useT();
  const leftRailOpen = useUiStore((state) => state.leftRailOpen);
  const isSettingsOpen = useUiStore((state) => state.isSettingsOpen);
  const locale = useLocale();
  const [activeCategory, setActiveCategory] = useState<SettingsPanelId>(() =>
    isSettingsCategoryId(initialCategory) ? normalizeSettingsCategoryId(initialCategory) : "general",
  );
  useEffect(() => {
    if (isSettingsCategoryId(initialCategory)) setActiveCategory(normalizeSettingsCategoryId(initialCategory));
  }, [initialCategory]);
  const [query, setQuery] = useState("");
  const [searchTarget, setSearchTarget] = useState<string | null>(null);
  const [settingsAttempt, setSettingsAttempt] = useState(0);
  const [settingsLoadError, setSettingsLoadError] = useState(false);
  const [milestonesOpen, setMilestonesOpen] = useState(false);
  const [settings, setSettings] = useState<Settings | null>(null);
  const [appearance, setAppearance] = useState<AppearanceSettings>(() =>
    pickAppearance(DEFAULT_SETTINGS),
  );
  const [themeSaving, setThemeSaving] = useState(false);
  const [themeErrorKey, setThemeErrorKey] = useState<string | null>(null);
  const connections = useAgentConnectionStore(state => state.connections);
  const availability = Object.fromEntries(AGENT_PROVIDERS.map(provider => [provider, connections[provider].availability])) as ProviderState<AgentAvailability | null>;
  const availabilityLoading = Object.fromEntries(AGENT_PROVIDERS.map(provider => [provider, connections[provider].loading || connections[provider].availability === null && connections[provider].availabilityError === null])) as ProviderState<boolean>;
  const availabilityError = Object.fromEntries(AGENT_PROVIDERS.map(provider => [provider, connections[provider].availabilityError])) as ProviderState<string | null>;
  const [agentProviderSaving, setAgentProviderSaving] = useState(false);
  const [agentProviderFeedbackKey, setAgentProviderFeedbackKey] = useState<
    string | null
  >(null);
  const [courses, setCourses] = useState<Course[]>([]);
  const [coursesLoading, setCoursesLoading] = useState(true);
  const [coursesError, setCoursesError] = useState<string | null>(null);
  const [includeArchived, setIncludeArchived] = useState(false);
  const [pendingCourseId, setPendingCourseId] = useState<string | null>(null);
  const mountedRef = useRef(true);
  const settingsPushVersion = useRef(0);
  const coursesRequest = useRef(0);
  const searchInputRef = useRef<HTMLInputElement>(null);
  const selectedCourseId = useCoursesStore((state) => state.selectedCourseId);
  const plugins = usePluginsStore((state) => state.plugins);
  const milestoneProgress = useMilestones((state) => state.progress);
  const refreshMilestones = useMilestones((state) => state.refresh);

  const categories = useMemo<readonly Category[]>(
    () =>
      SETTINGS_CATEGORIES.map(({ id, group }) => ({
        id,
        group,
        label: t(`settings.category.${id}.label`),
        description: t(`settings.category.${id}.description`),
      })),
    [t],
  );

  const active =
    categories.find((category) => category.id === activeCategory) ??
    categories[0]!;

  const searchResults = useMemo(
    () => searchSettings(query, locale, plugins.map((plugin) => plugin.manifest)),
    [locale, query, plugins],
  );
  const matchesByCategory = useMemo(
    () => new Map(searchResults.map((result) => [result.category, result.matches])),
    [searchResults],
  );
  const filteredCategories = useMemo(
    () => categories.filter((category) => matchesByCategory.has(category.id)),
    [categories, matchesByCategory],
  );

  const loadAvailability = useCallback((target?: AgentProvider): void => {
    for (const provider of target === undefined ? AGENT_PROVIDERS : [target]) void refreshAgentConnection(provider, true);
  }, []);

  const loadCourses = (showArchived: boolean): void => {
    const request = ++coursesRequest.current;
    setCoursesLoading(true);
    setCoursesError(null);
    void invoke("courses:list", { includeArchived: showArchived })
      .then((result) => {
        if (mountedRef.current && request === coursesRequest.current) setCourses(result.filter(course => course.workspaceKind !== 'study-space'));
      })
      .catch(() => {
        if (mountedRef.current && request === coursesRequest.current) setCoursesError("courses-failed");
      })
      .finally(() => {
        if (mountedRef.current && request === coursesRequest.current) setCoursesLoading(false);
      });
  };

  useEffect(() => {
    mountedRef.current = true;
    let active = true;
    let pushed = false;
    setSettingsLoadError(false);
    const unsubscribe = onPush("settings:changed", ({ settings: next }) => {
      pushed = true;
      settingsPushVersion.current += 1;
      setSettingsLoadError(false);
      setSettings(next);
      setAppearance(pickAppearance(next));
      if (!embedded) applyTheme(next);
    });

    void invoke("settings:get", {})
      .then((result) => {
        if (!active || pushed) return;
        setSettings(result);
        setAppearance(pickAppearance(result));
        if (!embedded) applyTheme(result);
      })
      .catch(() => {
        if (active && !pushed) {
          setSettingsLoadError(true);
          setThemeErrorKey("settings.appearance.loadFailed");
        }
      });

    loadCourses(includeArchived);

    return () => {
      active = false;
      mountedRef.current = false;
      coursesRequest.current += 1;
      unsubscribe();
    };
  }, [embedded, loadAvailability, settingsAttempt]);

  useEffect(() => {
    const panelRoot = document.querySelector('.settings-panel');
    if (!panelRoot || !searchTarget) return;
    let highlighted: Element | null = null;
    const locate = (): void => {
      if (highlighted) return;
      const label = [...panelRoot.querySelectorAll('.setting-row__label, .settings-card h2, label, h3')]
        .find((node) => node.textContent?.toLocaleLowerCase().includes(searchTarget.toLocaleLowerCase()));
      highlighted = label?.closest('.setting-row, .settings-card') ?? label ?? null;
      if (!highlighted) return;
      const details = highlighted.closest('details');
      if (details) details.open = true;
      highlighted.setAttribute('data-search-match', 'true');
      highlighted.scrollIntoView?.({ block: 'center', behavior: 'instant' });
      highlighted.querySelector<HTMLElement>('button, input, select, textarea')?.focus({ preventScroll: true });
    };
    locate();
    const observer = new MutationObserver(locate);
    observer.observe(panelRoot, { childList: true, subtree: true });
    return () => { observer.disconnect(); highlighted?.removeAttribute('data-search-match'); };
  }, [activeCategory, searchTarget]);

  useEffect(() => {
    if (embedded && !isSettingsOpen) return;
    const releases = AGENT_PROVIDERS.map(provider => acquireAgentConnection(provider, true));
    return () => releases.forEach(release => release());
  }, [embedded, isSettingsOpen]);

  useEffect(() => {
    if (embedded) return;
    document.documentElement.lang = locale;
    document.title = `${t("settings.app.name")} — ${t("settings.window.title")}`;
  }, [embedded, locale, t]);

  useEffect(() => {
    void refreshMilestones(selectedCourseId);
  }, [refreshMilestones, selectedCourseId]);

  useEffect(() => {
    if (embedded) return;
    const media = window.matchMedia("(prefers-color-scheme: light)");
    const handleChange = (): void => {
      if (appearance.theme === "system") applyTheme(appearance);
    };
    media.addEventListener("change", handleChange);
    return () => media.removeEventListener("change", handleChange);
  }, [embedded, appearance]);

  /**
   * Every appearance axis saves the same way: paint optimistically, persist
   * the patch, then reconcile with whatever main actually stored (and roll
   * the whole set back on failure — a half-applied appearance is worse than
   * neither).
   */
  const saveAppearance = (patch: Partial<AppearanceSettings>): void => {
    if (themeSaving) return;
    const previous = appearance;
    const pushVersion = settingsPushVersion.current;
    const next = { ...previous, ...patch };
    if (isSameAppearance(next, previous)) return;
    setAppearance(next);
    if (!embedded) applyTheme(next);
    setThemeSaving(true);
    setThemeErrorKey(null);

    void invoke("settings:set", patch)
      .then((nextSettings) => {
        if (!mountedRef.current || pushVersion !== settingsPushVersion.current) return;
        setSettings(nextSettings);
        setAppearance(pickAppearance(nextSettings));
        if (!embedded) applyTheme(nextSettings);
      })
      .catch(() => {
        if (!mountedRef.current) return;
        if (pushVersion === settingsPushVersion.current) {
          setAppearance(previous);
          if (!embedded) applyTheme(previous);
        }
        setThemeErrorKey("settings.appearance.saveFailed");
      })
      .finally(() => {
        if (mountedRef.current) setThemeSaving(false);
      });
  };

  const handleThemeSelect = (theme: ThemePreference): void => {
    saveAppearance({ theme });
  };


  const handleFontScaleSelect = (fontScale: FontScale): void => {
    saveAppearance({ fontScale });
  };

  const handleEditorFontSelect = (editorFont: EditorFont): void => {
    saveAppearance({ editorFont });
  };

  const handleDensitySelect = (density: Density): void => {
    saveAppearance({ density });
  };


  const handleAgentProviderSelect = (nextProvider: AgentProvider): void => {
    if (
      settings === null ||
      nextProvider === settings.agentProvider ||
      agentProviderSaving
    ) {
      return;
    }

    const previousProvider = settings.agentProvider;
    const pushVersion = settingsPushVersion.current;
    setSettings((current) =>
      current === null ? current : { ...current, agentProvider: nextProvider },
    );
    setAgentProviderSaving(true);
    setAgentProviderFeedbackKey("settings.ai.engine.saving");

    void invoke("settings:set", { agentProvider: nextProvider })
      .then((nextSettings) => {
        if (!mountedRef.current) return;
        if (pushVersion === settingsPushVersion.current) setSettings(nextSettings);
        setAgentProviderFeedbackKey("settings.ai.engine.saved");
      })
      .catch(() => {
        if (!mountedRef.current) return;
        if (pushVersion === settingsPushVersion.current) setSettings((current) =>
          current === null
            ? current
            : { ...current, agentProvider: previousProvider },
        );
        setAgentProviderFeedbackKey("settings.ai.engine.saveFailed");
      })
      .finally(() => {
        if (mountedRef.current) setAgentProviderSaving(false);
      });
  };

  const handleArchivedChange = (next: boolean): void => {
    setIncludeArchived(next);
    loadCourses(next);
  };

  const handleRestoreCourse = async (course: Course): Promise<void> => {
    if (pendingCourseId !== null) return;
    setPendingCourseId(course.id);
    try {
      const restored = await invoke("courses:archive", {
        courseId: course.id,
        archived: false,
      });
      if (!mountedRef.current) return;
      setCourses((current) =>
        current.map((item) => (item.id === restored.id ? restored : item)),
      );
      showToast(
        locale === "ko-KR"
          ? `“${course.name}” 과목을 복원했어요.`
          : `Restored “${course.name}”.`,
      );
    } catch {
      if (mountedRef.current) {
        showToast(
          locale === "ko-KR"
            ? "과목을 복원하지 못했어요."
            : "Could not restore the course.",
          "danger",
        );
      }
    } finally {
      if (mountedRef.current) setPendingCourseId(null);
    }
  };

  const runMilestoneAction = (id: MilestoneId): void => {
    setMilestonesOpen(false);
    const destination = milestoneDestination(id);
    if (destination === "settings-university" || destination === "settings-ai") {
      setActiveCategory(
        destination === "settings-university" ? "university" : "ai",
      );
      return;
    }

    if (embedded) onClose?.();
    else window.close();
    if (destination === "course") {
      window.dispatchEvent(new CustomEvent(ADD_COURSE_SHORTCUT_EVENT));
    } else if (destination === "materials") {
      const ui = useUiStore.getState();
      if (!ui.rightRailOpen) ui.toggleRightRail();
      window.requestAnimationFrame(() => {
        window.dispatchEvent(new CustomEvent(IMPORT_MATERIALS_SHORTCUT_EVENT));
      });
    } else if (destination === "tour") {
      void useTourStore.getState().start();
    } else if (destination === "pip") {
      document
        .querySelector<HTMLButtonElement>(".file-video__pip:not(:disabled)")
        ?.click();
    } else {
      window.dispatchEvent(
        new CustomEvent(HELP_FOCUS_TARGET_EVENT, {
          detail: { target: destination },
        }),
      );
    }
  };

  const panel: Record<SettingsPanelId, ReactNode> = {
    tabs: null,
    account: <AccountPanel />,
    general: <GeneralPanel settings={settings} />,
    appearance: (
      <AppearancePanel
        theme={appearance.theme}
        fontScale={appearance.fontScale}
        editorFont={appearance.editorFont}
        density={appearance.density}
        saving={themeSaving}
        error={themeErrorKey === null ? null : t(themeErrorKey)}
        onSelect={handleThemeSelect}
        onSelectFontScale={handleFontScaleSelect}
        onSelectEditorFont={handleEditorFontSelect}
        onSelectDensity={handleDensitySelect}
      />
    ),
    widgets: <WidgetSettingsPanel settings={settings} />,
    packs: <PluginsCategoryPanel searchTarget={searchTarget} initialFilter={initialCategory === "mcp" ? "external" : "all"} />,
    ai: (
      <AiPanel
        provider={settings?.agentProvider ?? "claude-code"}
        providerReady={settings !== null}
        providerSaving={agentProviderSaving}
        providerFeedback={
          agentProviderFeedbackKey === null ? null : t(agentProviderFeedbackKey)
        }
        providerFeedbackError={
          agentProviderFeedbackKey === "settings.ai.engine.saveFailed"
        }
        availability={availability}
        loading={availabilityLoading}
        error={availabilityError}
        onProviderSelect={handleAgentProviderSelect}
        onRetry={loadAvailability}
      />
    ),
    assistant: <AssistantPanel settings={settings} />,
    calendar: <CalendarSettingsPanel />,
    browser: <BrowserSettingsPanel settings={settings} />,
    notifications: <NotificationsPanel settings={settings} />,
    usage: <UsagePanel />,
    shortcuts: <ShortcutsPanel settings={settings} />,
    permissions: <PermissionsPanel />,
    privacy: <PrivacyPanel />,
    advanced: <AdvancedPanel settings={settings} />,
    experimental: <ExperimentalPanel settings={settings} />,
    university: <UniversitySettingsPanel />,
    courses: (
      <CoursesPanel
        courses={courses}
        loading={coursesLoading}
        error={coursesError}
        includeArchived={includeArchived}
        pendingCourseId={pendingCourseId}
        onIncludeArchivedChange={handleArchivedChange}
        onRestore={(course) => void handleRestoreCourse(course)}
        onRetry={() => loadCourses(includeArchived)}
      />
    ),
    about: <AboutPanel />,
  } satisfies Record<SettingsPanelId, ReactNode>;
  panel.tabs = <TabsSettingsPanel settings={settings} aiPanel={panel.ai} browserPanel={panel.browser} onNavigate={(category) => setActiveCategory(normalizeSettingsCategoryId(category))} />;

  return (
    <div
      className={`settings-app${embedded ? " settings-app--embedded" : ""}`}
      onKeyDown={(event) => {
        if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "f") {
          event.preventDefault();
          searchInputRef.current?.focus();
        }
      }}
    >
      {!embedded && (
        <header className="settings-titlebar titlebar-drag">
          <div className="settings-titlebar__brand">
            <BandalMark size={17} className="settings-titlebar__moon" />
            <span>{t("settings.app.name")}</span>
          </div>
          <span className="settings-titlebar__divider" aria-hidden="true" />
          <span className="settings-titlebar__label">
            {t("settings.window.title")}
          </span>
        </header>
      )}

      <div className="settings-layout">
        <aside
          className="settings-sidebar"
          aria-hidden={embedded && !leftRailOpen}
          {...{ inert: embedded && !leftRailOpen ? '' : undefined }}
          aria-label={t("settings.navigation.label")}
        >
          <button
            type="button"
            className="back-button"
            onClick={() => {
              if (embedded) onClose?.();
              else window.close();
            }}
          >
            <Icon name="arrow-left" size={17} />
            <span>{t("settings.back")}</span>
          </button>

          <label className="settings-search">
            <span className="visually-hidden">
              {t("settings.search.label")}
            </span>
            <Icon name="search" size={16} />
            <input
              ref={searchInputRef}
              type="search"
              value={query}
              placeholder={t("settings.search.placeholder")}
              onChange={(event) => setQuery(event.target.value)}
              onKeyDown={(event) => {
                if (event.key === "Escape") setQuery("");
              }}
            />
            {query.length === 0 && (
              <span className="settings-search__kbd" aria-hidden="true">
                <kbd>{window.bandal?.platform === "darwin" ? "⌘" : "Ctrl"}</kbd>
                <kbd>F</kbd>
              </span>
            )}
          </label>

          <button
            type="button"
            className="settings-checklist"
            onClick={() => {
              setMilestonesOpen(true);
              void refreshMilestones(selectedCourseId);
            }}
          >
            <Icon name="checklist" />
            <span>{t("settings.checklist.label")}</span>
            <span className="settings-checklist__status">
              {milestoneProgress >= 100 ? (
                <span role="img" aria-label={t("settings.checklist.complete")}>
                  <Icon name="check" />
                </span>
              ) : (
                <ProgressRing
                  compact
                  progress={milestoneProgress}
                  label={t("help.milestones.progress")}
                />
              )}
            </span>
          </button>

          <nav className="settings-nav">
            {SETTINGS_GROUPS.map((group) => {
              const groupCategories = filteredCategories.filter(
                (category) => category.group === group,
              );
              if (groupCategories.length === 0) return null;
              return (
                <div className="settings-nav__group" key={group}>
                  <span className="settings-nav__group-label">
                    {t(`settings.group.${group}`)}
                  </span>
                  {groupCategories.map((category) => {
                    const matches = matchesByCategory.get(category.id) ?? [];
                    return (
                      <div key={category.id}>
                      <button
                        type="button"
                        data-category={category.id}
                        className={`settings-nav__item${
                          activeCategory === category.id
                            ? " settings-nav__item--active"
                            : ""
                        }`}
                        aria-current={
                          activeCategory === category.id ? "page" : undefined
                        }
                        onClick={() => { setSearchTarget(query.trim() ? matches[0] ?? null : null); setActiveCategory(category.id); }}
                      >
                        <Icon name={category.id} />
                        <span className="settings-nav__copy">
                          <span>{category.label}</span>
                          {query.trim().length > 0 && matches.length > 0 && (
                            <span className="settings-nav__hits">
                              {matches.slice(0, 3).join(" · ")}
                            </span>
                          )}
                        </span>
                      </button>
                      {query.trim() && matches.map((match) => <button className="settings-search-hit" key={match} type="button" onClick={() => {
                        setSearchTarget(match); setActiveCategory(category.id);
                      }}>{match}</button>)}
                      </div>
                    );
                  })}
                </div>
              );
            })}
            {filteredCategories.length === 0 && (
              <div className="settings-nav__empty">
                <Icon name="search" size={17} />
                <span>{t("settings.search.empty")}</span>
              </div>
            )}
          </nav>

          <div className="settings-sidebar__footer">
            <BandalMark size={14} className="settings-sidebar__footer-moon" />
            <span>{t("settings.tagline")}</span>
          </div>
        </aside>

        <main className="settings-content" tabIndex={-1}>
          {embedded && !leftRailOpen && <button type="button" className="back-button settings-content__back" onClick={onClose}>
            <Icon name="arrow-left" size={17} /><span>{t("settings.back")}</span>
          </button>}
          <div className="settings-content__inner">
            {settingsLoadError && <div role="alert" className="settings-extension-feedback">
              {t('settings.appearance.loadFailed')}
              <button type="button" className="secondary-button" onClick={() => setSettingsAttempt((n) => n + 1)}>{t('settings.plugins.action.retry')}</button>
            </div>}
            <header className="content-heading">
              <h1>{active.label}</h1>
              <p>{active.description}</p>
            </header>
            <div className="settings-panel" key={active.id}>
              {panel[active.id]}
            </div>
          </div>
        </main>
      </div>
      <MilestonesOverlay
        open={milestonesOpen}
        selectedCourseId={selectedCourseId}
        onClose={() => setMilestonesOpen(false)}
        onTry={runMilestoneAction}
      />
      <ToastHost />
    </div>
  );
}
