"""Shared runtime construction for application and durable worker.

The adopted GLM combines the verified JSON-action understanding protocol with
strict phased-plan output. The base SiliconFlowPlanner remains available for
historical comparison, and other explicitly selected models keep that class.
Construction performs no model or public-web request.
"""
from copy import deepcopy
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from ai_service import (DEFAULT_MODEL, GLM_FLASH_MODEL, SiliconFlowPlanner,
                        AiServiceError, validate_goal_request)
from experimental_action_protocol import JsonActionUnderstandingPlanner
from experimental_plan_schema import StrictLongTermPlanner
from long_term_planner import planning_context


def _workspace_preferences(workspace):
    """Validate/whitelist execution context without exporting private objects."""
    try:
        prefs = workspace['preferences']
        if not isinstance(prefs, dict):
            raise ValueError()
        weekdays = prefs['weekdays']
        if (not isinstance(weekdays, list) or not weekdays or
                any(type(day) is not int or not 1 <= day <= 7 for day in weekdays) or
                len(set(weekdays)) != len(weekdays)):
            raise ValueError()
        ranges = {'dailyBudget': (15, 480), 'startMinute': (0, 1439),
                  'endMinute': (1, 1440), 'bufferMinutes': (0, 120)}
        for field, (minimum, maximum) in ranges.items():
            if type(prefs[field]) is not int or not minimum <= prefs[field] <= maximum:
                raise ValueError()
        rest_start, rest_end = prefs.get('restStart', 720), prefs.get('restEnd', 780)
        if (type(rest_start) is not int or type(rest_end) is not int or
                not 0 <= rest_start <= rest_end <= 1439 or prefs['startMinute'] >= prefs['endMinute']):
            raise ValueError()
        zone = prefs.get('timeZone', 'Asia/Hong_Kong')
        if not isinstance(zone, str) or not 1 <= len(zone) <= 100:
            raise ValueError()
        ZoneInfo(zone)
    except (KeyError, TypeError, ValueError, ZoneInfoNotFoundError):
        raise AiServiceError('请先同步有效的个人排期偏好，再生成规划。', 400, 'invalid_ai_request') from None
    scheduling = {field: deepcopy(prefs[field]) for field in
                  ('weekdays', 'startMinute', 'endMinute', 'bufferMinutes')}
    scheduling.update(restStart=rest_start, restEnd=rest_end)
    return prefs['dailyBudget'], zone, scheduling


class GlmRuntimePlanner(JsonActionUnderstandingPlanner, StrictLongTermPlanner):
    """understand from JSON actions; generate from strict phased planning.

Both share SiliconFlowPlanner's request-local configuration and safe transport.
    No method wraps another model call, and neither operation rewrites its result.
    """

    def generate_for_workspace(self, body, workspace):
        if workspace is None or (isinstance(workspace, dict) and 'preferences' not in workspace):
            # A first-time account may not have synced preferences yet. Keep
            # the existing explicit-request/default-context behavior available.
            return self.generate(body)
        goal = validate_goal_request(body)
        preference_budget, preference_zone, scheduling = _workspace_preferences(workspace)
        execution_goal = {**goal, 'dailyBudget': min(goal['dailyBudget'], preference_budget)}
        execution_goal.setdefault('timeZone', preference_zone)
        try:
            context = planning_context(execution_goal)
        except ValueError as error:
            raise AiServiceError(str(error), 400, 'invalid_ai_request') from None
        context['schedulingContext'] = scheduling
        return self._generate_context(context)


def create_planner(api_key='', model=DEFAULT_MODEL, timeout=45, *, public_web_factory=None):
    planner_class = GlmRuntimePlanner if model == GLM_FLASH_MODEL else SiliconFlowPlanner
    return planner_class(api_key, model, timeout, public_web_factory=public_web_factory)
