"""Strict phased-plan schema, selected for GLM by model_runtime."""
from copy import deepcopy

from ai_service import (AiServiceError, SiliconFlowPlanner, _TimedPayload,
                        validate_ai_tasks, validate_goal_request)
from long_term_planner import (MAX_PHASES, MAX_TASKS, PLAN_TIMEOUT_SECONDS,
                               build_payload, normalize_plan, planning_context)

STRICT_PLAN_SCHEMA = {
    'type': 'object', 'additionalProperties': False, 'required': ['phases', 'tasks'],
    'properties': {
        'phases': {'type': 'array', 'minItems': 1, 'maxItems': MAX_PHASES, 'items': {
            'type': 'object', 'additionalProperties': False,
            'required': ['id', 'title', 'start', 'end', 'outcome'],
            'properties': {
                'id': {'type': 'string', 'pattern': '^[A-Za-z0-9_-]{1,40}$'},
                'title': {'type': 'string', 'minLength': 1, 'maxLength': 100},
                'start': {'type': 'string', 'format': 'date-time'},
                'end': {'type': 'string', 'format': 'date-time'},
                'outcome': {'type': 'string', 'minLength': 1, 'maxLength': 2000},
            }}},
        'tasks': {'type': 'array', 'minItems': 1, 'maxItems': MAX_TASKS, 'items': {
            'type': 'object', 'additionalProperties': False,
            'required': ['title', 'notes', 'estimatedMinutes', 'checklist', 'phaseId'],
            'properties': {
                'title': {'type': 'string', 'minLength': 1, 'maxLength': 200},
                'notes': {'type': 'string', 'maxLength': 10000},
                'estimatedMinutes': {'type': 'integer', 'minimum': 5, 'maximum': 240, 'multipleOf': 5},
                'checklist': {'type': 'array', 'maxItems': 8, 'items': {
                    'type': 'string', 'minLength': 1, 'maxLength': 500}},
                'phaseId': {'type': 'string', 'pattern': '^[A-Za-z0-9_-]{1,40}$'},
            }}},
    },
}

WORKSPACE_SCHEDULING_RULES = (
    '\n本次schedulingContext来自该账号已验证的排期偏好，工作日、工作时窗、休息和缓冲是硬约束。'
    'dailyBudget已取本次目标选择与个人每日偏好的较小值，是优先遵守的每日投入目标。'
    'weekdays使用ISO星期1至7，只能在这些当地星期安排工作；startMinute/endMinute是当地每日可用时窗，'
    'restStart/restEnd之间不可工作（相等表示无休息段），bufferMinutes也会减少可容纳的任务间隔。'
    '依timeZone的实际当地日历，逐阶段核算阶段起止范围内的可用工作日数、首尾不完整工作日、'
    '每日工作时窗扣除休息及缓冲后的实际容量；阶段全部任务必须在真实可用时窗和阶段截止内完成。'
    '优先将工作拆成可执行的小任务，但不要为迎合dailyBudget虚假缩短估时或省略必要工作。'
    '若只超出每日投入目标而仍能满足这些硬约束，可如实保留任务估时；'
    '客户端会计算有限的额外投入并展示待确认候选，必须由用户明确确认后才能执行。'
    '你不能代替用户确认额外投入，也不能自行改变个人偏好。'
    '必要时重新选择合理阶段窗口、任务数量或工作量，但不得越过目标截止、增加可用星期、'
    '扩大实际工作时窗、占用休息或借用另一个阶段的容量。'
    '没有提供私人日历忙块，不代表日历为空；最终真实冲突仍由排期引擎检查，不宣称已成功排入。'
)


def plan_schema(daily_budget):
    # Keep the request argument compatible. A daily target is prompt context,
    # not the hard limit on an honest task estimate or a splittable task.
    return deepcopy(STRICT_PLAN_SCHEMA)


class StrictLongTermPlanner(SiliconFlowPlanner):
    """Strict phased output with model-owned stages and validated time bounds."""

    def generate(self, body):
        goal = validate_goal_request(body)
        try:
            context = planning_context(goal)
        except ValueError as error:
            raise AiServiceError(str(error), 400, 'invalid_ai_request') from None
        return self._generate_context(context)

    def _generate_context(self, context):
        payload = build_payload(self.model, context)
        if 'schedulingContext' in context:
            payload['messages'][0]['content'] += WORKSPACE_SCHEDULING_RULES
        payload['response_format'] = {'type': 'json_schema', 'json_schema': {
            'name': 'sera_phased_plan', 'strict': True, 'schema': plan_schema(context['dailyBudget'])}}
        value, model = self._complete(_TimedPayload(payload, PLAN_TIMEOUT_SECONDS))
        try:
            if not isinstance(value, dict) or set(value) != {'phases', 'tasks'}:
                raise ValueError('严格阶段规划只能包含phases和tasks')
            result = normalize_plan(value, context, validate_ai_tasks)
        except ValueError as error:
            raise AiServiceError('AI 阶段规划无效：' + str(error), code='invalid_ai_output') from None
        return {**result, 'source': 'siliconflow', 'model': model}
