module PaymentRouting
  module Constants
    # Вес, который получает единственная активная стратегия (solo-режим).
    SOLO_TARGET_WEIGHT = 0.70
    # Суммарный вес, который делится между остальными (неактивными) стратегиями в solo-режиме.
    SOLO_OTHERS_TOTAL_WEIGHT = 0.30
    # Нижняя граница веса неактивной стратегии в solo-режиме (не даёт ей обнулиться).
    SOLO_OTHER_MIN_WEIGHT = 0.05

    # Показатель степени у LoadFactor: по умолчанию и когда активна стратегия "интенсивность".
    DEFAULT_GAMMA = 2
    INTENSITY_GAMMA = 4

    # Множитель, приводящий итоговый рейтинг к шкале 0..100.
    SCORE_SCALE = 100

    # Границы, в которые клиппится нормированный компонент рейтинга.
    NORM_MIN = 0.0
    NORM_MAX = 1.0
    NEUTRAL_NORM = 0.5

    # Границы, в которые клиппится относительное отклонение (rd) до перевода в norm.
    RELATIVE_DEVIATION_MIN = -1.0
    RELATIVE_DEVIATION_MAX = 1.0

    # Значение нормы по умолчанию когда её нельзя посчитать
    UNDEFINED_UTILIZATION = 0.0
    SINGLE_CANDIDATE_NORM = 1.0

    # Ширина скользящего окна для интенсивности
    RPM_WINDOW_SECONDS = 60
  end
end
